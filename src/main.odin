package main

import "core:fmt"
import "base:runtime"
import "core:mem"
import "core:time"
import win32 "core:sys/windows"

WINDOW_CLASS := win32.L("ElgaCameraOdinWindow")
WINDOW_TITLE := win32.L("Elgato 4K X")
FRAME_ARENA_SIZE :: 64 * 1024
SCREENSHOT_FEEDBACK_DURATION :: 4*time.Second
UI_TIMER           :: 1
REDRAW_RETRY_TIMER  :: 2
UI_ACTION_MESSAGE   :: win32.WM_APP + 2
CAPTURE_FAILED_MESSAGE :: win32.WM_APP + 3
CAPTURE_READY_MESSAGE  :: win32.WM_APP + 4
EDID_RESULT_MESSAGE    :: win32.WM_APP + 5

// UI widgets post these so state changes run outside ImGui frame building.
UI_Action :: enum u32 {
	Fullscreen,
	Pin,
	Topmost,
	Audio,
	Wake,
	Minimize,
	Maximize,
	Close,
	Output,
	Color_Format,
	Resolution,
	Screenshot,
	FPS_Visible,
	Reconnect,
	EDID_Mode,
	EDID_Refresh,
	Color_Range,
	Video_Super_Resolution,
	Video_Frame_Generation,
	Video_Game_30_FPS,
}

App :: struct {
	hwnd:          win32.HWND,
	fullscreen:    bool,
	fps_visible:   bool,
	position_pin:  bool,
	always_on_top: bool,
	renderer:      Renderer,
	audio:         Audio_State,
	wake:          Wake_Control,
	ui:            ImGui_State,
	layout:        Window_Layout_State,
	screenshot:    Screenshot_State,
	screenshot_feedback_until: time.Time,
	screenshot_feedback_shown: bool,
	frame_arena:   mem.Arena,
	frame_memory:  [FRAME_ARENA_SIZE]byte,
	windowed_rect: win32.RECT,
	windowed_style: win32.LONG_PTR,
	// The custom title bar is persistent while windowed and hover-revealed in fullscreen.
	controls_visible: bool,
	hover_started:    time.Time,
	last_ui_tick:     time.Time,
	pinned_x:         i32,
	pinned_y:         i32,
	device_lost_shown: bool,
}

app: App

main :: proc() {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	// Prevent Windows from bitmap-scaling the window and blurring the capture UI.
	win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

	if failed(win32.CoInitializeEx(nil, .MULTITHREADED)) do fatal("COM initialization failed")
	defer win32.CoUninitialize()

	instance := cast(win32.HINSTANCE)win32.GetModuleHandleW(nil)
	wc := win32.WNDCLASSEXW {
		cbSize        = size_of(win32.WNDCLASSEXW),
		style         = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
		lpfnWndProc   = window_proc,
		hInstance     = instance,
		hCursor       = win32.LoadCursorA(nil, win32.IDC_ARROW),
		lpszClassName = cstring16(WINDOW_CLASS),
	}
	if win32.RegisterClassExW(&wc) == 0 do fatal("RegisterClassExW failed")

	// Retain the standard top-level window semantics and DWM shadow. WM_NCCALCSIZE
	// below removes its non-client frame so the client-rendered bar is the only
	// title bar the user sees.
	width, height := default_window_size(win32.USER_DEFAULT_SCREEN_DPI)
	hwnd := win32.CreateWindowExW(
		0, cstring16(WINDOW_CLASS), cstring16(WINDOW_TITLE), win32.WS_OVERLAPPEDWINDOW,
		win32.CW_USEDEFAULT, win32.CW_USEDEFAULT, width, height,
		nil, nil, instance, nil,
	)
	if hwnd == nil do fatal("CreateWindowExW failed")
	// Window dimensions are physical pixels in per-monitor-aware mode. Preserve
	// the intended video area plus its title bar on scaled displays.
	if dpi := win32.GetDpiForWindow(hwnd); dpi != win32.USER_DEFAULT_SCREEN_DPI {
		width, height = default_window_size(dpi)
		win32.SetWindowPos(hwnd, nil, 0, 0, width, height, win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE)
	}
	// Force Windows to recalculate the client area before the first ShowWindow;
	// otherwise DWM may keep the standard caption until the first resize.
	win32.SetWindowPos(hwnd, nil, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED)
	set_window_frame_appearance(hwnd, false)

	app.hwnd = hwnd
	window_layout_restore(&app.layout, hwnd)
	app.always_on_top = app.layout.always_on_top
	app.fps_visible = true
	app.controls_visible = true
	mem.arena_init(&app.frame_arena, app.frame_memory[:])

	client: win32.RECT
	win32.GetClientRect(hwnd, &client)
	if !renderer_init(&app.renderer, hwnd, u32(client.right), u32(client.bottom)) do fatal("D3D11 initialization failed")
	if !imgui_ui_init(&app.ui, &app.renderer) do fatal("Dear ImGui DX11 initialization failed")
	audio_init(&app.audio)
	video_enhancements_init(&app.renderer.enhancements, &app.audio)
	wake_init(&app.wake)
	win32.SetTimer(hwnd, UI_TIMER, 100, nil)

	win32.ShowWindow(hwnd, win32.SW_SHOW)
	win32.UpdateWindow(hwnd)

	msg: win32.MSG
	for {
		// Generated frames have deadlines between capture arrivals. Drain queued
		// input first, then wait for either messages or the presentation timer.
		if app.renderer.enhancements.timer != nil && .Frame_Generation in app.renderer.enhancements.preferences {
			if !win32.PeekMessageW(&msg, nil, 0, 0, win32.PM_REMOVE) {
				handles := [1]win32.HANDLE{app.renderer.enhancements.timer}
				result := win32.MsgWaitForMultipleObjects(1, &handles[0], false, win32.INFINITE, win32.QS_ALLINPUT)
				if result == win32.WAIT_OBJECT_0 do renderer_request_redraw(&app.renderer)
				continue
			}
			if msg.message == win32.WM_QUIT do break
			win32.TranslateMessage(&msg)
			win32.DispatchMessageW(&msg)
			continue
		}
		if win32.GetMessageW(&msg, nil, 0, 0) <= 0 {
			break
		}
		win32.TranslateMessage(&msg)
		win32.DispatchMessageW(&msg)
	}

	wake_destroy(&app.wake)
	audio_destroy(&app.audio)
	imgui_ui_destroy(&app.ui)
	screenshot_destroy(&app.screenshot)
	renderer_destroy(&app.renderer)
}


screenshot_feedback_visible :: proc() -> bool {
	return screenshot_busy(&app.screenshot) || time.diff(time.now(), app.screenshot_feedback_until) > 0
}

ui_tick :: proc() {
	now := time.now()
	// WM_TIMER has lower priority than paints. Also tick from paints, bounded
	// to 10 Hz, so a busy capture cannot delay hover controls or wake feedback.
	if app.last_ui_tick != {} && time.diff(app.last_ui_tick, now) < 100*time.Millisecond do return
	app.last_ui_tick = now
	changed := wake_update(&app.wake)
	changed |= renderer_update_reconnect(&app.renderer)
	changed |= app_update_device_recovery()
	capture_health_update(&app.renderer)
	video_enhancements_health_tick(&app.renderer)
	if !app.renderer.drawing && screenshot_update(&app.screenshot, &app.renderer) {
		app.screenshot_feedback_until = time.time_add(now, SCREENSHOT_FEEDBACK_DURATION)
		changed = true
	}
	feedback_shown := screenshot_feedback_visible()
	changed |= feedback_shown != app.screenshot_feedback_shown
	app.screenshot_feedback_shown = feedback_shown

	point: win32.POINT
	win32.GetCursorPos(&point)
	window_rect: win32.RECT
	win32.GetWindowRect(app.hwnd, &window_rect)
	bar_height := title_bar_height_for_dpi(win32.GetDpiForWindow(app.hwnd))
	inside := point.x >= window_rect.left && point.x < window_rect.right &&
		point.y >= window_rect.top && point.y < min(window_rect.top+bar_height, window_rect.bottom)
	// Fullscreen reveals the bar after hovering the top edge for two seconds.
	visible := !app.fullscreen || app.ui.menu_open
	if !visible && inside {
		if app.hover_started == {} do app.hover_started = now
		visible = time.diff(app.hover_started, now) >= 2*time.Second
	} else if !visible {
		app.hover_started = {}
	}
	changed |= app.controls_visible != visible
	app.controls_visible = visible
	if changed || (visible && (inside || app.ui.menu_open)) do renderer_request_ui_redraw(&app.renderer)

	when ELGA_FULLSCREEN_STRESS do fullscreen_stress_tick()
	when ELGA_FORMAT_STRESS do format_stress_tick()
	when ELGA_DEVICE_LOSS_STRESS do device_loss_stress_tick()
}

post_ui_action :: proc(action: UI_Action, value := 0) {
	win32.PostMessageW(app.hwnd, UI_ACTION_MESSAGE, win32.WPARAM(action), win32.LPARAM(value))
}

apply_ui_action :: proc(action: UI_Action, value: int) {
	switch action {
	case .Fullscreen:
		toggle_fullscreen()
	case .Pin:
		app.position_pin = !app.position_pin
		if app.position_pin {
			r: win32.RECT
			win32.GetWindowRect(app.hwnd, &r)
			app.pinned_x, app.pinned_y = r.left, r.top
		}
	case .Topmost:
		app.always_on_top = !app.always_on_top
		target := win32.HWND_TOPMOST if app.always_on_top else win32.HWND_NOTOPMOST
		win32.SetWindowPos(app.hwnd, target, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOACTIVATE)
		save_window_layout(app.hwnd)
	case .Audio:
		audio_set_muted(&app.audio, !audio_is_muted(&app.audio))
	case .Wake:
		wake_request(&app.wake)
	case .Screenshot:
		if app.renderer.reconnect_thread == nil {
			screenshot_request(&app.screenshot, &app.renderer)
			app.screenshot_feedback_until = time.time_add(time.now(), SCREENSHOT_FEEDBACK_DURATION)
			renderer_request_redraw(&app.renderer)
		}
	case .FPS_Visible:
		app.fps_visible = !app.fps_visible
		renderer_request_redraw(&app.renderer)
	case .Reconnect:
		renderer_request_reconnect(&app.renderer)
	case .EDID_Mode:
		if value >= 0 && value < len(EDID_Mode) do renderer_request_edid_mode(&app.renderer, EDID_Mode(value))
	case .EDID_Refresh:
		renderer_request_edid_refresh(&app.renderer)
	case .Color_Range:
		if value >= 0 && value < len(Color_Range) do renderer_request_color_range(&app.renderer, Color_Range(value))
	case .Video_Super_Resolution:
		video_enhancements_toggle(&app.renderer, .Super_Resolution)
	case .Video_Frame_Generation:
		video_enhancements_toggle(&app.renderer, .Frame_Generation)
	case .Video_Game_30_FPS:
		video_enhancements_toggle(&app.renderer, .Game_30_FPS)
	case .Minimize:
		win32.ShowWindow(app.hwnd, win32.SW_MINIMIZE)
	case .Maximize:
		if app.fullscreen {
			toggle_fullscreen()
		} else {
			win32.ShowWindow(app.hwnd, win32.SW_RESTORE if win32.IsZoomed(app.hwnd) else win32.SW_MAXIMIZE)
		}
	case .Close:
		win32.PostMessageW(app.hwnd, win32.WM_CLOSE, 0, 0)
	case .Output:
		// Zero selects the Windows default output.
		audio_select_output(&app.audio, value-1)
	case .Color_Format:
		// CAPTURE_FORMAT_COUNT selects Auto.
		if value == CAPTURE_FORMAT_COUNT {
			renderer_set_capture_format_auto(&app.renderer)
		} else if value >= 0 && value < CAPTURE_FORMAT_COUNT {
			renderer_set_capture_format(&app.renderer, Capture_Format(value))
		}
	case .Resolution:
		// Width and height packed into one value; zero selects Auto.
		packed := u64(value)
		renderer_set_capture_resolution(&app.renderer, u32(packed>>32), u32(packed))
	}
}

fatal :: proc(message: string) {
	fmt.eprintln(message)
	wide := win32.utf8_to_utf16(message)
	win32.MessageBoxW(nil, cstring16(&wide[0]), cstring16(WINDOW_TITLE), win32.MB_OK | win32.MB_ICONERROR)
	win32.ExitProcess(1)
}
