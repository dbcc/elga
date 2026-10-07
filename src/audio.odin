package main

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:sync"
import ma "vendor:miniaudio"

MAX_AUDIO_OUTPUTS         :: 64
AUDIO_CHANNELS            :: 2
AUDIO_SAMPLE_RATE         :: 48_000
AUDIO_VOLUME_DEFAULT      :: 100
AUDIO_SETTINGS_FILE       :: "elga-camera.ini"

Audio_Device_Name :: [ma.MAX_DEVICE_NAME_LENGTH + 1]u8

Audio_Output :: struct {
	id: ma.device_id,
	name: Audio_Device_Name,
}

// The 4K X's capture endpoint is monitored through a duplex WASAPI stream.
// muted and volume_percent are read by the audio callback thread.
Audio_State :: struct {
	video_delay: Audio_Video_Delay,
	ctx: ma.context_type,
	device: ma.device,
	context_ready: bool,
	device_ready: bool,
	muted: u32,
	volume_percent: u32,
	settings_dirty: bool,
	settings_save_failed: bool,
	capture_id: ma.device_id,
	capture_name: Audio_Device_Name,
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

audio_device_name :: proc(name: ^Audio_Device_Name) -> string {
	length := 0
	for length < len(name)-1 && name[length] != 0 do length += 1
	return string(name[:length])
}

audio_enumerate :: proc(a: ^Audio_State) -> bool {
	playback: [^]ma.device_info
	capture: [^]ma.device_info
	playback_count, capture_count: u32
	if ma.context_get_devices(&a.ctx, &playback, &playback_count, &capture, &capture_count) != .SUCCESS do return false
	a.output_count = min(int(playback_count), MAX_AUDIO_OUTPUTS)
	for i in 0..<a.output_count {
		a.outputs[i] = {id = playback[i].id, name = playback[i].name}
		// The UI draws this buffer as a C string.
		a.outputs[i].name[len(Audio_Device_Name)-1] = 0
	}
	// Prefer the full product name over another device that merely contains "4K X".
	best := -1
	for i in 0..<int(capture_count) {
		name := transmute([]u8)audio_device_name(&capture[i].name)
		if contains_ascii_fold(name, "elgato 4k x") {
			best = i
			break
		}
		if best < 0 && contains_ascii_fold(name, "4k x") do best = i
	}
	if best < 0 do return false
	a.capture_id = capture[best].id
	a.capture_name = capture[best].name
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
	if output_index >= 0 do config.playback.pDeviceID = &a.outputs[output_index].id
	result := ma.device_init(&a.ctx, &config, &a.device)
	if result != .SUCCESS {
		fmt.eprintf("audio: device initialization failed (%d)\n", result)
		return false
	}
	a.device_ready = true
	if ma.device_start(&a.device) != .SUCCESS {
		audio_close_device(a)
		fmt.eprintln("audio: could not start the monitor stream")
		return false
	}
	a.selected_output = output_index
	output_name := "Windows default" if output_index < 0 else audio_device_name(&a.outputs[output_index].name)
	fmt.eprintf("audio: %s -> %s (48 kHz stereo, WASAPI shared)\n", audio_device_name(&a.capture_name), output_name)
	return true
}

// An index of -1 selects the Windows default output. On failure, falls back to
// the previous output and then the default.
audio_select_output :: proc(a: ^Audio_State, output_index: int) -> bool {
	if !a.context_ready || output_index < -1 || output_index >= a.output_count do return false
	if a.device_ready && output_index == a.selected_output do return true
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

// Changing the volume also unmutes, matching common media-player behavior.
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
	path, _, paths_ok := settings_paths(AUDIO_SETTINGS_FILE)
	return paths_ok && audio_load_settings_from_path(a, path)
}

audio_load_settings_from_path :: proc(a: ^Audio_State, path: string) -> bool {
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	if read_error != nil do return false
	percent := audio_parse_volume_settings(string(data)) or_return
	sync.atomic_store_explicit(&a.volume_percent, percent, .Relaxed)
	a.settings_dirty = false
	a.settings_save_failed = false
	return true
}

audio_save_settings :: proc(a: ^Audio_State) -> bool {
	if !a.settings_dirty do return !a.settings_save_failed
	path, temp_path, paths_ok := settings_paths(AUDIO_SETTINGS_FILE)
	if !paths_ok {
		a.settings_save_failed = true
		return false
	}
	return audio_save_settings_to_paths(a, path, temp_path)
}

audio_save_settings_to_paths :: proc(a: ^Audio_State, path, temp_path: string) -> bool {
	if !a.settings_dirty do return !a.settings_save_failed
	buffer: [64]byte
	if !settings_write(path, temp_path, audio_format_volume_settings(buffer[:], audio_get_volume_percent(a))) {
		a.settings_save_failed = true
		return false
	}
	a.settings_dirty = false
	a.settings_save_failed = false
	return true
}

audio_format_volume_settings :: proc(buffer: []byte, percent: u32) -> string {
	return fmt.bprintf(buffer, "[audio]\r\nvolume_percent=%d\r\n", min(percent, u32(100)))
}

audio_parse_volume_settings :: proc(data: string) -> (percent: u32, ok: bool) {
	it := Ini_Iterator{data = data, section = "[audio]"}
	for key, value in ini_next(&it) {
		if key != "volume_percent" do continue
		parsed, valid := strconv.parse_int(value, 10)
		if !valid || parsed < 0 || parsed > 100 do break
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
	// device_stop has joined the callback; discard audio from the old device.
	a.video_delay.cursor, a.video_delay.filled = 0, 0
	a.video_delay.fade = AUDIO_VIDEO_FADE_FRAMES
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
	if audio_video_delay_samples(&a.video_delay, output_samples, input_samples) do input_samples = output_samples
	audio_apply_volume_samples(output_samples, input_samples, audio_get_volume_percent(a), audio_is_muted(a))
}

audio_apply_volume_samples :: proc "contextless" (output, input: []f32, volume_percent: u32, muted: bool) {
	sample_count := min(len(output), len(input))
	// The callback disables Miniaudio's pre-silencing, so fill every output sample.
	if len(output) > sample_count do mem.zero(raw_data(output[sample_count:]), (len(output)-sample_count)*size_of(f32))
	if muted || volume_percent == 0 {
		mem.zero(raw_data(output[:sample_count]), sample_count*size_of(f32))
		return
	}
	if volume_percent >= 100 {
		if raw_data(output) != raw_data(input) do mem.copy_non_overlapping(raw_data(output[:sample_count]), raw_data(input[:sample_count]), sample_count*size_of(f32))
		return
	}
	gain := f32(volume_percent)/100.0
	for i in 0..<sample_count do output[i] = input[i]*gain
}
