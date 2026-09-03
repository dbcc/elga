package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import "core:sync"
import ma "vendor:miniaudio"

MAX_AUDIO_OUTPUTS         :: 64
AUDIO_CHANNELS            :: 2
AUDIO_SAMPLE_RATE         :: 48_000
AUDIO_VOLUME_DEFAULT      :: 100
AUDIO_SETTINGS_FILE       :: "elga-camera.ini"
AUDIO_SETTINGS_TEMP_FORMAT :: "elga-camera.ini.%d.tmp"

Audio_Output :: struct {
	id: ma.device_id,
	name: [ma.MAX_DEVICE_NAME_LENGTH + 1]u8,
	name_len: int,
	is_default: bool,
}

Audio_State :: struct {
	ctx: ma.context_type,
	device: ma.device,
	context_ready: bool,
	device_ready: bool,
	muted: u32,
	volume_percent: u32,
	settings_dirty: bool,
	settings_save_failed: bool,
	capture_id: ma.device_id,
	capture_name: [ma.MAX_DEVICE_NAME_LENGTH + 1]u8,
	capture_name_len: int,
	outputs: [MAX_AUDIO_OUTPUTS]Audio_Output,
	output_count: int,
	selected_output: int,
}

audio_init :: proc(a: ^Audio_State) -> bool {
	a.selected_output = -1
	sync.atomic_store_explicit(&a.volume_percent, AUDIO_VOLUME_DEFAULT, .Relaxed)
	audio_load_settings(a)
	backends := [1]ma.backend{.wasapi}
	config := ma.context_config_init()
	if ma.context_init(raw_data(backends[:]), 1, &config, &a.ctx) != .SUCCESS {
		fmt.eprintln("audio: could not initialize WASAPI")
		return false
	}
	a.context_ready = true
	if !audio_enumerate(a) {
		fmt.eprintln("audio: Elgato 4K X audio endpoint was not found")
		ma.context_uninit(&a.ctx)
		a.context_ready = false
		return false
	}
	return audio_open_device(a, -1)
}

audio_enumerate :: proc(a: ^Audio_State) -> bool {
	playback: [^]ma.device_info
	capture: [^]ma.device_info
	playback_count, capture_count: u32
	if ma.context_get_devices(&a.ctx, &playback, &playback_count, &capture, &capture_count) != .SUCCESS do return false
	a.output_count = min(int(playback_count), MAX_AUDIO_OUTPUTS)
	for i in 0..<a.output_count {
		a.outputs[i].id = playback[i].id
		a.outputs[i].name_len = copy_device_name(&a.outputs[i].name, &playback[i].name)
		a.outputs[i].is_default = bool(playback[i].isDefault)
	}
	best := -1
	for i in 0..<int(capture_count) {
		if device_name_contains(&capture[i].name, "elgato 4k x") { best = i; break }
		if best < 0 && device_name_contains(&capture[i].name, "4k x") do best = i
	}
	if best < 0 do return false
	a.capture_id = capture[best].id
	a.capture_name_len = copy_device_name(&a.capture_name, &capture[best].name)
	return true
}

audio_open_device :: proc(a: ^Audio_State, output_index: int) -> bool {
	if !a.context_ready do return false
	if output_index < -1 || output_index >= a.output_count do return false
	audio_close_device(a)
	config := ma.device_config_init(.duplex)
	config.sampleRate = AUDIO_SAMPLE_RATE
	config.periodSizeInMilliseconds = 5
	config.periods = 3
	config.performanceProfile = .low_latency
	config.noPreSilencedOutputBuffer = true
	config.noFixedSizedCallback = true
	config.dataCallback = audio_callback
	config.pUserData = a
	config.playback.format = .f32
	config.playback.channels = AUDIO_CHANNELS
	config.playback.shareMode = .shared
	config.capture.pDeviceID = &a.capture_id
	config.capture.format = .f32
	config.capture.channels = AUDIO_CHANNELS
	config.capture.shareMode = .shared
	config.wasapi.usage = .pro_audio
	if output_index >= 0 && output_index < a.output_count do config.playback.pDeviceID = &a.outputs[output_index].id
	result := ma.device_init(&a.ctx, &config, &a.device)
	if result != .SUCCESS {
		fmt.eprintf("audio: device initialization failed (%d)\n", result)
		return false
	}
	a.device_ready = true
	if ma.device_start(&a.device) != .SUCCESS {
		ma.device_uninit(&a.device)
		a.device_ready = false
		fmt.eprintln("audio: could not start the monitor stream")
		return false
	}
	a.selected_output = output_index
	output_name := "Windows default"
	if output_index >= 0 do output_name = string(a.outputs[output_index].name[:a.outputs[output_index].name_len])
	fmt.eprintf("audio: %s -> %s (48 kHz stereo, WASAPI shared)\n", string(a.capture_name[:a.capture_name_len]), output_name)
	return true
}

audio_select_output :: proc(a: ^Audio_State, output_index: int) -> bool {
	old_index := a.selected_output
	if audio_open_device(a, output_index) do return true
	if old_index != output_index && audio_open_device(a, old_index) do return false
	if old_index != -1 do audio_open_device(a, -1)
	if !a.device_ready do a.selected_output = -1
	return false
}

audio_set_muted :: proc(a: ^Audio_State, muted: bool) {
	sync.atomic_store_explicit(&a.muted, u32(1) if muted else u32(0), .Relaxed)
}

audio_is_muted :: proc "contextless" (a: ^Audio_State) -> bool {
	return sync.atomic_load_explicit(&a.muted, .Relaxed) != 0
}

audio_get_volume_percent :: proc "contextless" (a: ^Audio_State) -> u32 {
	return sync.atomic_load_explicit(&a.volume_percent, .Relaxed)
}

audio_set_volume_percent :: proc(a: ^Audio_State, percent: u32) {
	clamped_percent := min(percent, u32(100))
	if audio_get_volume_percent(a) == clamped_percent do return
	sync.atomic_store_explicit(&a.volume_percent, clamped_percent, .Relaxed)
	audio_set_muted(a, false)
	a.settings_dirty = true
}

audio_settings_save_failed :: proc(a: ^Audio_State) -> bool {
	return a.settings_save_failed
}

audio_load_settings :: proc(a: ^Audio_State) -> bool {
	path, _, paths_ok := audio_settings_paths()
	if !paths_ok do return false
	return audio_load_settings_from_path(a, path)
}

audio_load_settings_from_path :: proc(a: ^Audio_State, path: string) -> bool {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil do return false
	percent, parsed := audio_parse_volume_settings(string(data))
	if !parsed do return false
	sync.atomic_store_explicit(&a.volume_percent, percent, .Relaxed)
	a.settings_dirty = false
	a.settings_save_failed = false
	return true
}

audio_save_settings :: proc(a: ^Audio_State) -> bool {
	if !a.settings_dirty do return !a.settings_save_failed
	path, temp_path, paths_ok := audio_settings_paths()
	if !paths_ok {
		a.settings_save_failed = true
		return false
	}
	return audio_save_settings_to_paths(a, path, temp_path)
}

audio_save_settings_to_paths :: proc(a: ^Audio_State, path, temp_path: string) -> bool {
	if !a.settings_dirty do return !a.settings_save_failed
	if !audio_write_volume_settings(path, temp_path, audio_get_volume_percent(a)) {
		a.settings_save_failed = true
		return false
	}
	a.settings_dirty = false
	a.settings_save_failed = false
	return true
}

audio_settings_paths :: proc() -> (path, temp_path: string, ok: bool) {
	directory, directory_error := os.get_executable_directory(context.temp_allocator)
	if directory_error != nil do return "", "", false
	return audio_settings_paths_for_directory(directory, os.get_pid())
}

audio_settings_paths_for_directory :: proc(directory: string, process_id: int) -> (path, temp_path: string, ok: bool) {
	settings_path, path_error := filepath.join([]string{directory, AUDIO_SETTINGS_FILE}, context.temp_allocator)
	if path_error != nil do return "", "", false
	temp_name := fmt.aprintf(AUDIO_SETTINGS_TEMP_FORMAT, process_id, allocator = context.temp_allocator)
	settings_temp_path, temp_path_error := filepath.join([]string{directory, temp_name}, context.temp_allocator)
	if temp_path_error != nil do return "", "", false
	return settings_path, settings_temp_path, true
}

audio_write_volume_settings :: proc(path, temp_path: string, percent: u32) -> bool {
	buffer: [64]byte
	settings := audio_format_volume_settings(buffer[:], percent)
	if os.write_entire_file(temp_path, settings) != nil {
		_ = os.remove(temp_path)
		return false
	}
	if os.rename(temp_path, path) != nil {
		_ = os.remove(temp_path)
		return false
	}
	return true
}

audio_format_volume_settings :: proc(buffer: []byte, percent: u32) -> string {
	return fmt.bprintf(buffer, "[audio]\r\nvolume_percent=%d\r\n", min(percent, u32(100)))
}

audio_parse_volume_settings :: proc(data: string) -> (percent: u32, ok: bool) {
	in_audio_section := false
	remaining := data
	for line in strings.split_lines_iterator(&remaining) {
		trimmed_line := strings.trim_space(line)
		if len(trimmed_line) == 0 || trimmed_line[0] == ';' || trimmed_line[0] == '#' do continue
		if trimmed_line[0] == '[' {
			in_audio_section = trimmed_line == "[audio]"
			continue
		}
		if !in_audio_section do continue
		equals := strings.index_byte(trimmed_line, '=')
		if equals < 0 do continue
		key := strings.trim_space(trimmed_line[:equals])
		if key != "volume_percent" do continue
		value := strings.trim_space(trimmed_line[equals+1:])
		parsed, valid := strconv.parse_int(value, 10)
		if !valid || parsed < 0 || parsed > 100 do return AUDIO_VOLUME_DEFAULT, false
		return u32(parsed), true
	}
	return AUDIO_VOLUME_DEFAULT, false
}

audio_destroy :: proc(a: ^Audio_State) {
	if a.settings_dirty do audio_save_settings(a)
	audio_close_device(a)
	if a.context_ready {
		ma.context_uninit(&a.ctx)
		a.context_ready = false
	}
}

audio_close_device :: proc(a: ^Audio_State) {
	if !a.device_ready do return
	ma.device_stop(&a.device)
	ma.device_uninit(&a.device)
	a.device_ready = false
}

audio_callback :: proc "c" (device: ^ma.device, output, input: rawptr, frame_count: u32) {
	if output == nil do return
	sample_count := int(frame_count) * AUDIO_CHANNELS
	a := cast(^Audio_State)device.pUserData
	if input == nil || a == nil {
		mem.zero(output, sample_count*size_of(f32))
		return
	}
	output_samples := (cast([^]f32)output)[:sample_count]
	input_samples := (cast([^]f32)input)[:sample_count]
	audio_apply_volume_samples(
		output_samples,
		input_samples,
		audio_get_volume_percent(a),
		audio_is_muted(a),
	)
}

audio_apply_volume_samples :: proc "contextless" (output, input: []f32, volume_percent: u32, muted: bool) {
	sample_count := min(len(output), len(input))
	if muted || volume_percent == 0 {
		mem.zero(raw_data(output[:sample_count]), sample_count*size_of(f32))
		return
	}
	if volume_percent >= 100 {
		mem.copy_non_overlapping(raw_data(output[:sample_count]), raw_data(input[:sample_count]), sample_count*size_of(f32))
		return
	}
	gain := f32(volume_percent)/100.0
	for i in 0..<sample_count do output[i] = input[i]*gain
}

copy_device_name :: proc(dst: ^[ma.MAX_DEVICE_NAME_LENGTH + 1]u8, src: ^[ma.MAX_DEVICE_NAME_LENGTH + 1]u8) -> int {
	i := 0
	for i < ma.MAX_DEVICE_NAME_LENGTH && src[i] != 0 { dst[i] = u8(src[i]); i += 1 }
	dst[i] = 0
	return i
}

device_name_contains :: proc(name: ^[ma.MAX_DEVICE_NAME_LENGTH + 1]u8, needle: string) -> bool {
	name_len := 0
	for name_len < ma.MAX_DEVICE_NAME_LENGTH && name[name_len] != 0 do name_len += 1
	if len(needle) == 0 do return true
	if len(needle) > name_len do return false
	for start in 0..=name_len-len(needle) {
		matched := true
		for j in 0..<len(needle) {
			a := u8(name[start+j]); b := needle[j]
			if a >= 'A' && a <= 'Z' do a += 'a'-'A'
			if b >= 'A' && b <= 'Z' do b += 'a'-'A'
			if a != b { matched = false; break }
		}
		if matched do return true
	}
	return false
}
