package main

import "core:fmt"
import "core:mem"
import "core:sync"
import ma "vendor:miniaudio"

MAX_AUDIO_OUTPUTS :: 64
AUDIO_CHANNELS    :: 2
AUDIO_SAMPLE_RATE :: 48_000

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
	capture_id: ma.device_id,
	capture_name: [ma.MAX_DEVICE_NAME_LENGTH + 1]u8,
	capture_name_len: int,
	outputs: [MAX_AUDIO_OUTPUTS]Audio_Output,
	output_count: int,
	selected_output: int,
}

audio_init :: proc(a: ^Audio_State) -> bool {
	a.selected_output = -1
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

audio_is_muted :: proc(a: ^Audio_State) -> bool {
	return sync.atomic_load_explicit(&a.muted, .Relaxed) != 0
}

audio_destroy :: proc(a: ^Audio_State) {
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
	byte_count := int(frame_count) * AUDIO_CHANNELS * size_of(f32)
	a := cast(^Audio_State)device.pUserData
	if input == nil || a == nil || sync.atomic_load_explicit(&a.muted, .Relaxed) != 0 {
		mem.zero(output, byte_count)
		return
	}
	mem.copy_non_overlapping(output, input, byte_count)
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
