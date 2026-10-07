package main

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:sync"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

VIDEO_ENHANCEMENT_MESSAGE :: win32.WM_APP + 6
VIDEO_BACKEND_ABI :: 3
VIDEO_VSR :: 1
VIDEO_FRUC :: 2

Video_Effect_State :: enum u32 { Off, Starting, Active, Not_Needed, Unavailable, Paused }
Video_Effect_Reason :: enum u32 { None, Runtime, Adapter, SDK, Display, Size, Late, Reset, Device }
Video_Config :: struct {
	width, height, output_width, output_height: u32,
	requested, generation, fps_num, fps_den: u32,
	refresh_hz: f64,
	game_fps, retry: u32,
}
Video_Frame :: struct {
	sequence: u64,
	timestamp, arrival: i64,
	generation, flipped: u32,
}
Video_Output :: struct {
	texture: ^d3d11.ITexture2D,
	token, sequence: u64,
	deadline: i64,
	generation, generated, flipped, reserved: u32,
}
Video_Status :: struct {
	vsr_state: Video_Effect_State,
	vsr_reason: Video_Effect_Reason,
	fruc_state: Video_Effect_State,
	fruc_reason: Video_Effect_Reason,
	missed, submitted, produced: u64,
	processing_ms, source_hz: f64,
	delay, next_deadline: i64,
	history: u64,
}
Video_Caps :: struct { supported: u32, vsr_reason, fruc_reason: Video_Effect_Reason, reserved: u32 }
Video_API :: struct {
	version, size: u32,
	query: proc "c" (^d3d11.IDevice, ^Video_Caps),
	create: proc "c" (^d3d11.IDevice, win32.HWND, u32) -> rawptr,
	configure: proc "c" (rawptr, ^Video_Config),
	submit: proc "c" (rawptr, ^d3d11.IDeviceContext, ^d3d11.ITexture2D, ^Video_Frame) -> u32,
	poll: proc "c" (rawptr, i64, ^Video_Output, ^Video_Status) -> u32,
	release: proc "c" (rawptr, u64),
	destroy: proc "c" (rawptr),
}
Video_Preferences :: struct { super_resolution, frame_generation, game_30_fps: bool }
Video_Preference :: enum { Super_Resolution, Frame_Generation, Game_30_FPS }
Video_Enhancements :: struct {
	preferences: Video_Preferences,
	loaded, load_attempted, save_failed: bool,
	module: win32.HMODULE,
	api: Video_API,
	session: rawptr,
	caps: Video_Caps,
	status: Video_Status,
	config: Video_Config,
	capture_generation, generation: u32,
	timer: win32.HANDLE,
	cached_texture: ^d3d11.ITexture2D,
	cached_view: ^d3d11.IShaderResourceView,
	cached: Video_Output,
	submitted_sequence, presented_token: u64,
	original_presented, generated_presented: u64,
	rate_original, rate_generated: u64,
	rate_start: i64,
	original_fps, generated_fps: f64,
	refresh_checked: i64,
	refresh_hz: f64,
	stalled: bool,
	output_failed: bool,
	history: u64,
	retry: u32,
	diagnostics: bool,
	diagnostic_time: i64,
}

foreign import enhancement_kernel "system:kernel32.lib"
foreign enhancement_kernel {
	CancelWaitableTimer :: proc "system" (timer: win32.HANDLE) -> win32.BOOL ---
}

video_now :: proc() -> i64 {
	q, f: win32.LARGE_INTEGER
	win32.QueryPerformanceCounter(&q)
	win32.QueryPerformanceFrequency(&f)
	return i64(q/f*10_000_000 + q%f*10_000_000/f)
}

video_preferences_parse :: proc(data: string) -> Video_Preferences {
	p: Video_Preferences
	section := false
	remaining := data
	for raw_line in strings.split_lines_iterator(&remaining) {
		line := strings.trim_space(raw_line)
		if strings.has_prefix(line, "[") { section = line == "[video]"; continue }
		if !section do continue
		separator := strings.index_byte(line, '=')
		if separator < 0 do continue
		key, value := line[:separator], line[separator+1:]
		key, value = strings.trim_space(key), strings.trim_space(value)
		switch key {
		case "super_resolution": p.super_resolution = value == "1"
		case "frame_generation": p.frame_generation = value == "1"
		case "game_30_fps": p.game_30_fps = value == "1"
		}
	}
	return p
}

video_preferences_paths :: proc() -> (path, temporary: string, ok: bool) {
	directory, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return
	settings_path, path_err := filepath.join([]string{directory, "elga-video.ini"}, context.temp_allocator)
	temp_path, temp_err := filepath.join([]string{directory, fmt.aprintf("elga-video.ini.%d.tmp", os.get_pid(), allocator = context.temp_allocator)}, context.temp_allocator)
	return settings_path, temp_path, path_err == nil && temp_err == nil
}

video_preferences_save_to :: proc(p: Video_Preferences, path, temporary: string) -> bool {
	buffer: [128]byte
	data := fmt.bprintf(buffer[:], "[video]\r\nsuper_resolution=%d\r\nframe_generation=%d\r\ngame_30_fps=%d\r\n", int(p.super_resolution), int(p.frame_generation), int(p.game_30_fps))
	if os.write_entire_file(temporary, data) != nil do return false
	if os.rename(temporary, path) != nil { _ = os.remove(temporary); return false }
	return true
}

video_enhancements_init :: proc(e: ^Video_Enhancements) {
	e.diagnostics = os.get_env("ELGA_VIDEO_DIAGNOSTICS", context.temp_allocator) == "1"
	path, _, ok := video_preferences_paths()
	if ok {
		data, read_ok := os.read_entire_file(path, context.temp_allocator)
		if read_ok == nil do e.preferences = video_preferences_parse(string(data))
	}
	e.status.vsr_state = .Starting if e.preferences.super_resolution else .Off
	e.status.fruc_state = .Starting if e.preferences.frame_generation else .Off
}

video_backend_valid :: proc(api: Video_API) -> bool {
	return api.version == VIDEO_BACKEND_ABI && api.size == size_of(Video_API) &&
		api.query != nil && api.create != nil && api.configure != nil && api.submit != nil &&
		api.poll != nil && api.release != nil && api.destroy != nil
}

video_backend_load :: proc(r: ^Renderer) {
	e := &r.enhancements
	if e.load_attempted do return
	e.load_attempted = true
	e.caps = {vsr_reason = .Runtime, fruc_reason = .Runtime}
	directory, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return
	path, path_err := filepath.join([]string{directory, "enhancements", "nvidia", "elga-video.dll"}, context.temp_allocator)
	if path_err != nil do return
	wide := win32.utf8_to_utf16(path)
	module := win32.LoadLibraryExW(cstring16(raw_data(wide)), nil, {.LOAD_LIBRARY_SEARCH_DLL_LOAD_DIR, .LOAD_LIBRARY_SEARCH_SYSTEM32})
	if module == nil do return
	get_api := cast(proc "c" (u32, u32, ^Video_API) -> u32)win32.GetProcAddress(module, "elga_video_get_api")
	api: Video_API
	if get_api == nil || get_api(VIDEO_BACKEND_ABI, size_of(Video_API), &api) == 0 || !video_backend_valid(api) {
		win32.FreeLibrary(module)
		return
	}
	e.module, e.api, e.loaded = module, api, true
	e.api.query(r.device_11, &e.caps)
}

video_enhancements_toggle :: proc(r: ^Renderer, preference: Video_Preference) {
	e := &r.enhancements
	switch preference {
	case .Super_Resolution: e.preferences.super_resolution = !e.preferences.super_resolution
	case .Frame_Generation: e.preferences.frame_generation = !e.preferences.frame_generation
	case .Game_30_FPS: e.preferences.game_30_fps = !e.preferences.game_30_fps
	}
	e.retry += 1
	path, temporary, ok := video_preferences_paths()
	e.save_failed = !ok || !video_preferences_save_to(e.preferences, path, temporary)
	video_enhancements_reset(r)
	if !e.loaded do e.load_attempted = false
	renderer_request_redraw(r)
}

video_enhancements_clear_cache :: proc(r: ^Renderer) {
	e := &r.enhancements
	com_release(e.cached_view)
	com_release(e.cached_texture)
	e.cached_view, e.cached_texture = nil, nil
	e.cached = {}
	e.presented_token = 0
}

// May be called before capture resources are released; no frame texture is
// retained by submit, and asynchronous worker results carry a new generation.
video_enhancements_reset :: proc(r: ^Renderer) {
	e := &r.enhancements
	video_enhancements_clear_cache(r)
	e.config = {}
	e.generation += 1
	e.submitted_sequence = 0
	e.status = {}
	e.history = 0
	e.output_failed = false
	e.status.vsr_state = .Starting if e.preferences.super_resolution else .Off
	e.status.fruc_state = .Starting if e.preferences.frame_generation else .Off
	e.original_fps, e.generated_fps = 0, 0
	e.rate_start = 0
	e.rate_original, e.rate_generated = e.original_presented, e.generated_presented
	if e.timer != nil do CancelWaitableTimer(e.timer)
	if e.timer != nil && !e.preferences.frame_generation { win32.CloseHandle(e.timer); e.timer = nil }
	if e.session != nil { disabled := Video_Config{generation = e.generation, retry = e.retry}; e.api.configure(e.session, &disabled) }
	if r == &app.renderer do audio_reset_video_delay(&app.audio)
}

video_enhancements_destroy :: proc(r: ^Renderer) {
	e := &r.enhancements
	video_enhancements_reset(r)
	if e.session != nil do e.api.destroy(e.session)
	if e.timer != nil do win32.CloseHandle(e.timer)
	if e.module != nil do win32.FreeLibrary(e.module)
	e^ = {}
}

video_display_refresh :: proc(r: ^Renderer) -> f64 {
	if r.swap_chain == nil do return 0
	output: ^dxgi.IOutput
	if failed(r.swap_chain.GetContainingOutput(r.swap_chain, &output)) do return 0
	defer com_release(output)
	desc: dxgi.OUTPUT_DESC
	if failed(output.GetDesc(output, &desc)) do return 0
	mode: win32.DEVMODEW
	mode.dmSize = size_of(mode)
	if !win32.EnumDisplaySettingsW(cstring16(&desc.DeviceName[0]), win32.ENUM_CURRENT_SETTINGS, &mode) do return 0
	return f64(mode.dmDisplayFrequency)
}

video_enhancements_prepare :: proc(r: ^Renderer) {
	e := &r.enhancements
	requested := (u32(VIDEO_VSR) if e.preferences.super_resolution else 0) | (u32(VIDEO_FRUC) if e.preferences.frame_generation else 0)
	if requested == 0 { e.status = {}; return }
	if e.stalled || e.output_failed do return
	video_backend_load(r)
	if !e.loaded || e.caps.supported&requested == 0 {
		e.status.vsr_state = .Unavailable if e.preferences.super_resolution else .Off
		e.status.fruc_state = .Unavailable if e.preferences.frame_generation else .Off
		e.status.vsr_reason, e.status.fruc_reason = e.caps.vsr_reason, e.caps.fruc_reason
		return
	}
	if e.session == nil {
		e.session = e.api.create(r.device_11, r.hwnd, VIDEO_ENHANCEMENT_MESSAGE)
		if e.session == nil { e.status.vsr_state, e.status.fruc_state = .Paused, .Paused; e.status.vsr_reason, e.status.fruc_reason = .Device, .Device; return }
	}
	if e.preferences.frame_generation && e.timer == nil {
		e.timer = win32.CreateWaitableTimerExW(nil, nil, 2, win32.TIMER_ALL_ACCESS)
		if e.timer == nil do e.timer = win32.CreateWaitableTimerExW(nil, nil, 0, win32.TIMER_ALL_ACCESS)
	}
	if e.timer == nil && requested&VIDEO_FRUC != 0 {
		requested &= ~u32(VIDEO_FRUC)
		e.status.fruc_state, e.status.fruc_reason = .Paused, .Device
	}
	view := video_viewport(r.width, r.height, r.video_top_inset)
	now := video_now()
	if e.refresh_checked == 0 || now-e.refresh_checked >= 10_000_000 {
		e.refresh_hz = video_display_refresh(r)
		e.refresh_checked = now
	}
	output_width := min(u32(view.Width), u32(3840))
	output_height := min(u32(view.Height), u32(2160))
	// Frame generation never depends on window size. Avoid rebuilding its device,
	// SDK session and history on every resize or toolbar visibility change.
	if !e.preferences.super_resolution || output_width <= r.resource_width || output_height <= r.resource_height {
		output_width, output_height = r.resource_width, r.resource_height
	}
	capture_generation := sync.atomic_load_explicit(&r.capture_generation, .Acquire)
	config := Video_Config{
		width = r.resource_width, height = r.resource_height,
		output_width = output_width, output_height = output_height,
		requested = requested, generation = e.generation,
		fps_num = r.mode.fps_num, fps_den = max(r.mode.fps_den, 1),
		refresh_hz = e.refresh_hz,
		game_fps = 30 if e.preferences.game_30_fps else 0,
		retry = e.retry,
	}
	if config != e.config || capture_generation != e.capture_generation {
		video_enhancements_clear_cache(r)
		e.generation += 1
		config.generation = e.generation
		e.config, e.capture_generation = config, capture_generation
		e.submitted_sequence = 0
		e.status = {}
		e.history = 0
		e.status.vsr_state = .Starting if e.preferences.super_resolution else .Off
		e.status.fruc_state = .Starting if e.preferences.frame_generation else .Off
		if r == &app.renderer do audio_reset_video_delay(&app.audio)
		e.api.configure(e.session, &config)
	}
	output: Video_Output
	has_output := e.api.poll(e.session, now, &output, &e.status) != 0
	if e.history != e.status.history {
		e.history = e.status.history
		video_enhancements_clear_cache(r)
		if r == &app.renderer do audio_reset_video_delay(&app.audio)
	}
	if has_output {
		defer e.api.release(e.session, output.token)
		if output.generation == e.generation && output.texture != nil {
			desc: d3d11.TEXTURE2D_DESC
			output.texture.GetDesc(output.texture, &desc)
			cached_desc: d3d11.TEXTURE2D_DESC
			if e.cached_texture != nil do e.cached_texture.GetDesc(e.cached_texture, &cached_desc)
			if e.cached_view == nil || desc.Width != cached_desc.Width || desc.Height != cached_desc.Height {
				video_enhancements_clear_cache(r)
				desc.MiscFlags = {}
				desc.BindFlags = {.SHADER_RESOURCE}
				if !failed(r.device_11.CreateTexture2D(r.device_11, &desc, nil, &e.cached_texture)) {
					r.device_11.CreateShaderResourceView(r.device_11, cast(^d3d11.IResource)e.cached_texture, nil, &e.cached_view)
				}
			}
			if e.cached_view != nil {
				r.context_11.CopyResource(r.context_11, cast(^d3d11.IResource)e.cached_texture, cast(^d3d11.IResource)output.texture)
				r.context_11.Flush(r.context_11)
				e.cached = output
				e.cached.texture = e.cached_texture
			} else {
				// A failed presentation texture must not leave delayed audio playing
				// alongside the native, undelayed fallback video.
				video_enhancements_reset(r)
				e.output_failed = true
				e.status.vsr_state = .Paused if e.preferences.super_resolution else .Off
				e.status.fruc_state = .Paused if e.preferences.frame_generation else .Off
				e.status.vsr_reason, e.status.fruc_reason = .Device, .Device
				return
			}
		}
	}
	if e.timer != nil {
		if e.status.next_deadline > 0 {
			due := win32.LARGE_INTEGER(-max(e.status.next_deadline-video_now(), 1))
			win32.SetWaitableTimerEx(e.timer, &due, 0, nil, nil, nil, 0)
		} else { CancelWaitableTimer(e.timer) }
	}
	if e.status.vsr_state != .Active && e.status.fruc_state != .Active do video_enhancements_clear_cache(r)
	if e.timer == nil && e.preferences.frame_generation do e.status.fruc_state, e.status.fruc_reason = .Paused, .Device
	if e.rate_start != 0 && now-e.rate_start >= 10_000_000 {
		e.original_fps, e.generated_fps = 0, 0
		e.rate_start = now
		e.rate_original, e.rate_generated = e.original_presented, e.generated_presented
	}
	if r == &app.renderer do audio_set_video_delay(&app.audio, e.status.delay)
}

video_enhancements_health_tick :: proc(r: ^Renderer) {
	e := &r.enhancements
	if e.session == nil do return
	if e.diagnostics && video_now()-e.diagnostic_time >= 20_000_000 {
		e.diagnostic_time = video_now()
		totals := capture_health_totals(&r.health)
		fmt.eprintf("Video timing: capture=%.2f display=%.2f original=%.2f generated=%.2f worker=%.2fms missed=%d history=%d submitted=%d produced=%d capture_drops=%d FG=%v/%v delay=%.2fms\n", r.health.capture_fps, e.refresh_hz, e.original_fps, e.generated_fps, e.status.processing_ms, e.status.missed, e.status.history, e.status.submitted, e.status.produced, totals.busy_drops, e.status.fruc_state, e.status.fruc_reason, f64(e.status.delay)/10000)
	}
	if r.health.capture_stalled && !e.stalled {
		video_enhancements_reset(r)
		e.stalled = true
		e.status.vsr_state = .Paused if e.preferences.super_resolution else .Off
		e.status.fruc_state = .Paused if e.preferences.frame_generation else .Off
		e.status.vsr_reason, e.status.fruc_reason = .Reset, .Reset
	} else if !r.health.capture_stalled && e.stalled {
		e.stalled = false
		renderer_request_redraw(r)
	}
}

video_enhancements_submit :: proc(r: ^Renderer, sequence: u64) {
	e := &r.enhancements
	if e.session == nil || e.config.requested == 0 || sequence == e.submitted_sequence do return
	// Continue cadence discovery on a slow display: repeated HDMI frames may
	// establish a lower source rate that this display can double. Paused/failed
	// effects, however, must not keep doing GPU work until explicitly retried.
	sr_work := e.status.vsr_state == .Active || e.status.vsr_state == .Starting
	fg_work := e.status.fruc_state == .Active || e.status.fruc_state == .Starting || e.status.fruc_state == .Not_Needed
	if !sr_work && !fg_work do return
	frame := Video_Frame{sequence = sequence, timestamp = r.video_timestamp, arrival = r.video_arrival,
		generation = e.generation, flipped = sync.atomic_load_explicit(&r.video_vertical_flip, .Acquire)}
	if e.api.submit(e.session, r.context_11, r.video_texture, &frame) != 0 do e.submitted_sequence = sequence
}

video_enhancement_text :: proc(state: Video_Effect_State, reason: Video_Effect_Reason) -> cstring {
	switch state {
	case .Off: return "Off"
	case .Starting: return "Starting..."
	case .Active: return "Active"
	case .Not_Needed:
		return "Not needed - display refresh is below the 2x target" if reason == .Display else "Not needed - image is already large enough"
	case .Unavailable:
		if reason == .Adapter do return "Unavailable - select the NVIDIA GPU in Windows graphics settings"
		if reason == .SDK do return "Unavailable - NVIDIA SDK does not support this device or driver"
		return "Unavailable - install the NVIDIA enhancement add-on"
	case .Paused:
		if reason == .Reset do return "Paused - waiting for capture to resume"
		if reason == .Late do return "Paused - processing cannot keep up; toggle off/on to retry"
		return "Paused - processing failed; toggle off/on to retry"
	}
	return "Unavailable"
}

video_enhancements_presented :: proc(r: ^Renderer) {
	e := &r.enhancements
	if e.cached.token == 0 || e.cached.token == e.presented_token do return
	e.presented_token = e.cached.token
	if e.cached.generated != 0 { e.generated_presented += 1 } else { e.original_presented += 1 }
	now := video_now()
	if e.rate_start == 0 do e.rate_start = now
	if now-e.rate_start >= 5_000_000 {
		e.original_fps = f64(e.original_presented-e.rate_original)*10_000_000/f64(now-e.rate_start)
		e.generated_fps = f64(e.generated_presented-e.rate_generated)*10_000_000/f64(now-e.rate_start)
		e.rate_original, e.rate_generated, e.rate_start = e.original_presented, e.generated_presented, now
	}
}
