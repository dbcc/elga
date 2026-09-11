package main

import "core:fmt"
import "base:runtime"
import "core:mem"
import "core:sync"
import "core:time"
import win32 "core:sys/windows"

WINDOW_CLASS := win32.L("ElgaCameraOdinWindow")
WINDOW_TITLE := win32.L("Elgato 4K X")
ASPECT_NUM   :: 16
ASPECT_DEN   :: 9
MIN_CLIENT_W :: 320
MIN_CLIENT_H :: 180
FRAME_ARENA_SIZE :: 64 * 1024
UI_TIMER           :: 1
REDRAW_RETRY_TIMER  :: 2
UI_ACTION_MESSAGE   :: win32.WM_APP + 2
CAPTURE_FAILED_MESSAGE :: win32.WM_APP + 3
CAPTURE_READY_MESSAGE  :: win32.WM_APP + 4
EDID_RESULT_MESSAGE    :: win32.WM_APP + 5
ELGA_FULLSCREEN_STRESS :: #config(ELGA_FULLSCREEN_STRESS, false)
ELGA_FORMAT_STRESS     :: #config(ELGA_FORMAT_STRESS, false)

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
	ColorFormat,
	Resolution,
	Screenshot,
	Reconnect,
	EDID_Mode,
	EDID_Refresh,
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
	controls_visible: bool,
	hover_started:    time.Time,
	last_ui_tick:     time.Time,
	pinned_x:         i32,
	pinned_y:         i32,
}

app: App
fullscreen_stress_started: time.Time
fullscreen_stress_step: int
format_stress_started: time.Time
format_stress_step: int

main :: proc() {
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	// Prevent Windows from bitmap-scaling the window and blurring the capture UI.
	win32.SetProcessDpiAwarenessContext(win32.DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)

	com_hr := win32.CoInitializeEx(nil, .MULTITHREADED)
	if failed(com_hr) {
		fatal("COM initialization failed")
	}
	defer win32.CoUninitialize()

	instance := win32.GetModuleHandleW(nil)
	wc := win32.WNDCLASSEXW {
		cbSize        = size_of(win32.WNDCLASSEXW),
		style         = win32.CS_HREDRAW | win32.CS_VREDRAW | win32.CS_OWNDC,
		lpfnWndProc   = window_proc,
		hInstance     = cast(win32.HINSTANCE)instance,
		hCursor       = win32.LoadCursorA(nil, win32.IDC_ARROW),
		lpszClassName = cstring16(WINDOW_CLASS),
	}
	if win32.RegisterClassExW(&wc) == 0 {
		fatal("RegisterClassExW failed")
	}

	client_w := 1280
	client_h := client_w * ASPECT_DEN / ASPECT_NUM + int(title_bar_height_for_dpi(96))
	// Retain the standard top-level window semantics and DWM shadow. WM_NCCALCSIZE
	// below removes its non-client frame so the client-rendered bar is the only
	// title bar the user sees.
	style := win32.WS_OVERLAPPEDWINDOW

	hwnd := win32.CreateWindowExW(
		0,
		cstring16(WINDOW_CLASS),
		cstring16(WINDOW_TITLE),
		style,
		win32.CW_USEDEFAULT,
		win32.CW_USEDEFAULT,
		i32(client_w),
		i32(client_h),
		nil,
		nil,
		cast(win32.HINSTANCE)instance,
		nil,
	)
	if hwnd == nil {
		fatal("CreateWindowExW failed")
	}
	// Window dimensions are physical pixels in per-monitor-aware mode. Preserve
	// the intended 1280x720 video area plus its title bar on scaled displays.
	window_dpi := win32.GetDpiForWindow(hwnd)
	if window_dpi != win32.USER_DEFAULT_SCREEN_DPI {
		scaled_client_w := client_w*int(window_dpi)/int(win32.USER_DEFAULT_SCREEN_DPI)
		scaled_client_h := (client_w*ASPECT_DEN/ASPECT_NUM)*int(window_dpi)/int(win32.USER_DEFAULT_SCREEN_DPI) + int(title_bar_height_for_dpi(window_dpi))
		win32.SetWindowPos(hwnd, nil, 0, 0, i32(scaled_client_w), i32(scaled_client_h), win32.SWP_NOMOVE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE)
	}
	// Force Windows to recalculate the client area before the first ShowWindow;
	// otherwise DWM may keep the standard caption until the first resize.
	win32.SetWindowPos(hwnd, nil, 0, 0, 0, 0, win32.SWP_NOMOVE | win32.SWP_NOSIZE | win32.SWP_NOZORDER | win32.SWP_NOACTIVATE | win32.SWP_FRAMECHANGED)
	set_window_frame_appearance(hwnd, false)

	app.hwnd = hwnd
	window_layout_restore(&app.layout, hwnd)
	app.always_on_top = app.layout.always_on_top
	app.fps_visible = true
	mem.arena_init(&app.frame_arena, app.frame_memory[:])

	client: win32.RECT
	win32.GetClientRect(hwnd, &client)
	if !renderer_init(&app.renderer, hwnd, u32(client.right), u32(client.bottom)) {
		fatal("D3D11 initialization failed")
	}
	if !imgui_ui_init(&app.ui, &app.renderer) {
		fatal("Dear ImGui DX11 initialization failed")
	}
	ui_init_state()
	audio_init(&app.audio)
	wake_init(&app.wake)
	win32.SetTimer(hwnd, UI_TIMER, 100, nil)

	win32.ShowWindow(hwnd, win32.SW_SHOW)
	win32.UpdateWindow(hwnd)

	msg: win32.MSG
	for {
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

window_proc :: proc "system" (hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) -> win32.LRESULT {
	context = runtime.default_context()
	// Settings and other work outside renderer_draw use the default scratch
	// arena. Rewind this callback's allocations without invalidating an outer
	// callback when Windows synchronously reenters the window procedure.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	imgui_ui_process_message(&app.ui, hwnd, msg, wparam, lparam)
	switch msg {
	case win32.WM_MOUSEMOVE, win32.WM_MOUSELEAVE,
	     win32.WM_LBUTTONDOWN, win32.WM_LBUTTONUP, win32.WM_LBUTTONDBLCLK,
	     win32.WM_RBUTTONDOWN, win32.WM_RBUTTONUP, win32.WM_RBUTTONDBLCLK,
	     win32.WM_MBUTTONDOWN, win32.WM_MBUTTONUP, win32.WM_MBUTTONDBLCLK,
	     win32.WM_MOUSEWHEEL, win32.WM_MOUSEHWHEEL:
		if app.controls_visible || app.ui.menu_open do renderer_request_ui_redraw(&app.renderer)
	case win32.WM_ERASEBKGND:
		return 1
	case win32.WM_PAINT:
		ps: win32.PAINTSTRUCT
		win32.BeginPaint(hwnd, &ps)
		// Validate before drawing so a capture arriving during the draw leaves
		// another paint pending. Windows coalesces paints behind mouse input.
		win32.EndPaint(hwnd, &ps)
		if app.renderer.ready {
			ui_tick()
			renderer_draw(&app.renderer)
		}
		return 0
	case UI_ACTION_MESSAGE:
		apply_ui_action(UI_Action(wparam), int(lparam))
		return 0
	case CAPTURE_FAILED_MESSAGE:
		renderer_edid_capture_failed(&app.renderer, u32(wparam))
		renderer_handle_capture_failure(&app.renderer, u32(wparam))
		renderer_request_redraw(&app.renderer)
		return 0
	case CAPTURE_READY_MESSAGE:
		if u32(wparam) == sync.atomic_load_explicit(&app.renderer.capture_generation, .Acquire) {
			renderer_edid_capture_ready(&app.renderer, u32(wparam))
			renderer_reconcile_auto_capture(&app.renderer)
		}
		return 0
	case EDID_RESULT_MESSAGE:
		renderer_handle_edid_result(&app.renderer, u32(wparam), u32(lparam))
		return 0
	case win32.WM_SIZE:
		if app.renderer.ready && wparam == win32.SIZE_MINIMIZED {
			renderer_suspend_capture(&app.renderer)
		} else if app.renderer.ready {
			w := u32(lparam & 0xffff)
			h := u32((lparam >> 16) & 0xffff)
			if w > 0 && h > 0 {
				renderer_request_resize(&app.renderer, w, h)
			}
		}
		return 0
	case win32.WM_TIMER:
		if u32(wparam) == UI_TIMER do ui_tick()
		if u32(wparam) == REDRAW_RETRY_TIMER {
			renderer_cancel_redraw_retry(&app.renderer)
			renderer_request_redraw(&app.renderer)
		}
		return 0
	case win32.WM_DPICHANGED:
		imgui_ui_set_dpi(&app.ui, u32(wparam & 0xffff))
		if !app.fullscreen {
			suggested := cast(^win32.RECT)uintptr(lparam)
			if suggested != nil {
				win32.SetWindowPos(
					hwnd, nil,
					suggested.left, suggested.top,
					suggested.right-suggested.left, suggested.bottom-suggested.top,
					win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
				)
			}
		}
		renderer_request_redraw(&app.renderer)
		return 0
	case win32.WM_NCCALCSIZE:
		if wparam != 0 {
			// Returning zero makes the whole window client area and removes the
			// standard caption. Maximized windows retain the system resize inset
			// so the custom bar is not clipped beyond the monitor work area.
			if !app.fullscreen && win32.IsZoomed(hwnd) {
				params := cast(^win32.NCCALCSIZE_PARAMS)uintptr(lparam)
				dpi := win32.GetDpiForWindow(hwnd)
				border_x := win32.GetSystemMetricsForDpi(win32.SM_CXSIZEFRAME, dpi) + win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi)
				border_y := win32.GetSystemMetricsForDpi(win32.SM_CYSIZEFRAME, dpi) + win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi)
				params.rgrc[0].left += border_x
				params.rgrc[0].top += border_y
				params.rgrc[0].right -= border_x
				params.rgrc[0].bottom -= border_y
			}
			return 0
		}
	case win32.WM_NCHITTEST:
		if app.fullscreen do return win32.HTCLIENT
		point := win32.POINT{win32.GET_X_LPARAM(lparam), win32.GET_Y_LPARAM(lparam)}
		win32.ScreenToClient(hwnd, &point)
		client: win32.RECT
		win32.GetClientRect(hwnd, &client)
		if !win32.IsZoomed(hwnd) {
			dpi := win32.GetDpiForWindow(hwnd)
			border_x := win32.GetSystemMetricsForDpi(win32.SM_CXSIZEFRAME, dpi) + win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi)
			border_y := win32.GetSystemMetricsForDpi(win32.SM_CYSIZEFRAME, dpi) + win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi)
			left, right := point.x < border_x, point.x >= client.right-border_x
			top, bottom := point.y < border_y, point.y >= client.bottom-border_y
			if top && left do return win32.HTTOPLEFT
			if top && right do return win32.HTTOPRIGHT
			if bottom && left do return win32.HTBOTTOMLEFT
			if bottom && right do return win32.HTBOTTOMRIGHT
			if left do return win32.HTLEFT
			if right do return win32.HTRIGHT
			if top do return win32.HTTOP
			if bottom do return win32.HTBOTTOM
		}
		dpi_scale := max(f32(win32.GetDpiForWindow(hwnd))/f32(win32.USER_DEFAULT_SCREEN_DPI), 1.0)
		controls_end := title_bar_controls_end(dpi_scale)
		right_controls_start := title_bar_wake_start(f32(client.right), dpi_scale)
		in_drag_region := f32(point.x) < TITLE_BAR_DRAG_WIDTH*dpi_scale ||
			(f32(point.x) >= controls_end && f32(point.x) < right_controls_start)
		if point.x >= 0 && in_drag_region && point.y >= 0 &&
			f32(point.y) < TITLE_BAR_HEIGHT*dpi_scale {
			return win32.HTCAPTION
		}
		return win32.HTCLIENT
	case win32.WM_MOVING:
		if app.position_pin {
			r := cast(^win32.RECT)uintptr(lparam)
			w, h := r.right-r.left, r.bottom-r.top
			r.left, r.top = app.pinned_x, app.pinned_y
			r.right, r.bottom = r.left+w, r.top+h
			return 1
		}
	case win32.WM_SETCURSOR:
		if u32(lparam & 0xffff) == win32.HTCLIENT {
			win32.SetCursor(win32.LoadCursorA(nil, win32.IDC_ARROW))
			return 1
		}
	case win32.WM_SIZING:
		if !app.fullscreen {
			r := cast(^win32.RECT)uintptr(lparam)
			enforce_16_9(r, u32(wparam))
			if app.position_pin && r != nil {
				w, h := r.right-r.left, r.bottom-r.top
				r.left, r.top = app.pinned_x, app.pinned_y
				r.right, r.bottom = r.left+w, r.top+h
			}
			return 1
		}
	case win32.WM_KEYDOWN:
		if lparam & (win32.LPARAM(1)<<30) != 0 do return 0
		switch u32(wparam) {
		case u32('F'), win32.VK_F11:
			toggle_fullscreen()
		case u32('P'):
			app.fps_visible = !app.fps_visible
			renderer_request_redraw(&app.renderer)
		case win32.VK_F8:
			post_ui_action(.Screenshot)
		}
		return 0
	case win32.WM_EXITSIZEMOVE:
		window_layout_observe(&app.layout, hwnd, app.fullscreen, app.always_on_top)
		window_layout_save(&app.layout)
		return 0
	case win32.WM_CLOSE:
		window_layout_observe(&app.layout, hwnd, app.fullscreen, app.always_on_top)
		window_layout_save(&app.layout)
		win32.DestroyWindow(hwnd)
		return 0
	case win32.WM_DESTROY:
		win32.KillTimer(hwnd, UI_TIMER)
		renderer_cancel_redraw_retry(&app.renderer)
		win32.PostQuitMessage(0)
		return 0
	}
	return win32.DefWindowProcW(hwnd, msg, wparam, lparam)
}

ui_init_state :: proc() {
	// The custom title bar is persistent while the app is windowed.
	app.controls_visible = true
}

ui_tick :: proc() {
	now := time.now()
	// WM_TIMER has lower priority than paints. Also tick from paints, bounded
	// to 10 Hz, so a busy capture cannot delay hover controls or wake feedback.
	if app.last_ui_tick != {} && time.diff(app.last_ui_tick, now) < 100*time.Millisecond do return
	app.last_ui_tick = now
	wake_changed := wake_update(&app.wake)
	reconnect_changed := renderer_update_reconnect(&app.renderer)
	capture_health_update(&app.renderer)
	screenshot_changed := false
	if !app.renderer.drawing do screenshot_changed = screenshot_update(&app.screenshot, &app.renderer)
	if screenshot_changed do app.screenshot_feedback_until = time.time_add(now, 4*time.Second)
	feedback_shown := screenshot_busy(&app.screenshot) || time.diff(now, app.screenshot_feedback_until) > 0
	feedback_changed := feedback_shown != app.screenshot_feedback_shown
	app.screenshot_feedback_shown = feedback_shown
	point: win32.POINT
	win32.GetCursorPos(&point)
	window_rect: win32.RECT
	win32.GetWindowRect(app.hwnd, &window_rect)
	bar_height := title_bar_height_for_dpi(win32.GetDpiForWindow(app.hwnd))
	inside := point.x >= window_rect.left && point.x < window_rect.right &&
		point.y >= window_rect.top && point.y < min(window_rect.top+bar_height, window_rect.bottom)
	visible := !app.fullscreen || app.ui.menu_open
	if app.fullscreen && !visible {
		if inside {
			if app.hover_started == {} {
				app.hover_started = now
			}
			visible = time.duration_seconds(time.diff(app.hover_started, now)) >= 2.0
		} else {
			app.hover_started = {}
		}
	}
	controls_changed := app.controls_visible != visible
	app.controls_visible = visible
	ui_interaction_active := app.controls_visible && (inside || app.ui.menu_open)
	if controls_changed || wake_changed || reconnect_changed || screenshot_changed || feedback_changed || ui_interaction_active do renderer_request_ui_redraw(&app.renderer)

	when ELGA_FULLSCREEN_STRESS do fullscreen_stress_tick()
	when ELGA_FORMAT_STRESS do format_stress_tick()
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
		window_layout_observe(&app.layout, app.hwnd, app.fullscreen, app.always_on_top)
		window_layout_save(&app.layout)
	case .Audio:
		audio_set_muted(&app.audio, !audio_is_muted(&app.audio))
	case .Wake:
		wake_request(&app.wake)
	case .Screenshot:
		if app.renderer.reconnect_thread == nil {
			screenshot_request(&app.screenshot, &app.renderer)
			app.screenshot_feedback_until = time.time_add(time.now(), 4*time.Second)
			renderer_request_redraw(&app.renderer)
		}
	case .Reconnect:
		renderer_request_reconnect(&app.renderer)
	case .EDID_Mode:
		if value >= 0 && value <= int(EDID_Mode.Merged) {
			renderer_request_edid_mode(&app.renderer, EDID_Mode(value))
		}
	case .EDID_Refresh:
		renderer_request_edid_refresh(&app.renderer)
	case .Minimize:
		win32.ShowWindow(app.hwnd, win32.SW_MINIMIZE)
	case .Maximize:
		if app.fullscreen {
			toggle_fullscreen()
		} else {
			command := win32.SW_RESTORE if win32.IsZoomed(app.hwnd) else win32.SW_MAXIMIZE
			win32.ShowWindow(app.hwnd, command)
		}
	case .Close:
		win32.PostMessageW(app.hwnd, win32.WM_CLOSE, 0, 0)
	case .Output:
		audio_select_output(&app.audio, value-1)
	case .ColorFormat:
		if value == CAPTURE_FORMAT_COUNT {
			renderer_set_capture_format_auto(&app.renderer)
		} else if value >= 0 && value < CAPTURE_FORMAT_COUNT {
			renderer_set_capture_format(&app.renderer, Capture_Format(value))
		}
	case .Resolution:
		packed := u64(value)
		renderer_set_capture_resolution(&app.renderer, u32(packed>>32), u32(packed))
	}
}

fullscreen_stress_tick :: proc() {
	when ELGA_FULLSCREEN_STRESS {
		if fullscreen_stress_started == {} {
			fullscreen_stress_started = time.now()
			return
		}
		target_step := min(int(time.duration_seconds(time.since(fullscreen_stress_started))/0.5), 12)
		for fullscreen_stress_step < target_step {
			toggle_fullscreen()
			fullscreen_stress_step += 1
			fmt.eprintf("fullscreen stress transition %d/12\n", fullscreen_stress_step)
		}
		if fullscreen_stress_step >= 12 {
			win32.PostMessageW(app.hwnd, win32.WM_CLOSE, 0, 0)
		}
	}
}

format_stress_tick :: proc() {
	when ELGA_FORMAT_STRESS {
		if format_stress_started == {} {
			format_stress_started = time.now()
			return
		}
		target_step := min(int(time.duration_seconds(time.since(format_stress_started))/3.0), 8)
		for format_stress_step < target_step {
			fmt.eprintf("mode stress state: %s %dx%d sequence=%d display=%.1f FPS\n", capture_format_name(app.renderer.capture_format), app.renderer.capture_width, app.renderer.capture_height, sync.atomic_load_explicit(&app.renderer.video_sequence, .Acquire), app.renderer.display_fps)
			switch format_stress_step {
			case 0:
				renderer_set_capture_resolution(&app.renderer, 1920, 1080)
			case 1:
				renderer_set_capture_resolution(&app.renderer, 1280, 720)
			case 2:
				renderer_set_capture_resolution(&app.renderer, 2560, 1440)
			case 3:
				renderer_set_capture_resolution(&app.renderer, 0, 0)
			case 4:
				renderer_set_capture_format(&app.renderer, .P010)
			case 5:
				renderer_set_capture_format(&app.renderer, .YUY2)
			case 6:
				renderer_set_capture_format(&app.renderer, .NV12)
			case 7:
				win32.PostMessageW(app.hwnd, win32.WM_CLOSE, 0, 0)
			}
			format_stress_step += 1
			fmt.eprintf("mode stress transition %d/8\n", format_stress_step)
		}
	}
}

title_bar_height_for_dpi :: proc(dpi: u32) -> i32 {
	// Match ImGui's minimum scale and round fractional rows up so the video
	// never shares a pixel with the bottom of the title bar.
	return (i32(TITLE_BAR_HEIGHT)*i32(max(dpi, win32.USER_DEFAULT_SCREEN_DPI)) + 95)/96
}

enforce_16_9 :: proc(rect: ^win32.RECT, edge: u32) {
	enforce_16_9_for_dpi(rect, edge, win32.GetDpiForWindow(app.hwnd))
}

enforce_16_9_for_dpi :: proc(rect: ^win32.RECT, edge, dpi: u32) {
	if rect == nil do return
	outer_w := rect.right - rect.left
	outer_h := rect.bottom - rect.top
	bar_height := title_bar_height_for_dpi(dpi)
	minimum_width := MIN_CLIENT_W*i32(dpi)/i32(win32.USER_DEFAULT_SCREEN_DPI)
	minimum_height := MIN_CLIENT_H*i32(dpi)/i32(win32.USER_DEFAULT_SCREEN_DPI)
	client_w := max(outer_w, minimum_width)
	client_h := max(outer_h-bar_height, minimum_height)

	// Vertical edges follow height; horizontal edges and corners follow width.
	// Comparing aspect-ratio errors always favors width because 16/9 > 1.
	width_led := edge != win32.WMSZ_TOP && edge != win32.WMSZ_BOTTOM
	if width_led {
		client_h = max(client_w * ASPECT_DEN / ASPECT_NUM, minimum_height)
	} else {
		client_w = max(client_h * ASPECT_NUM / ASPECT_DEN, minimum_width)
	}

	new_w := client_w
	new_h := client_h + bar_height
	if edge == win32.WMSZ_LEFT || edge == win32.WMSZ_TOPLEFT || edge == win32.WMSZ_BOTTOMLEFT {
		rect.left = rect.right - new_w
	} else {
		rect.right = rect.left + new_w
	}
	if edge == win32.WMSZ_TOP || edge == win32.WMSZ_TOPLEFT || edge == win32.WMSZ_TOPRIGHT {
		rect.top = rect.bottom - new_h
	} else {
		rect.bottom = rect.top + new_h
	}
}

toggle_fullscreen :: proc() {
	if app.hwnd == nil do return
	if !app.fullscreen {
		window_layout_observe(&app.layout, app.hwnd, false, app.always_on_top)
		app.windowed_style = win32.GetWindowLongPtrW(app.hwnd, win32.GWL_STYLE)
		if !bool(win32.GetWindowRect(app.hwnd, &app.windowed_rect)) do return
		monitor := win32.MonitorFromWindow(app.hwnd, .MONITOR_DEFAULTTONEAREST)
		info := win32.MONITORINFO{cbSize = size_of(win32.MONITORINFO)}
		if monitor == nil || !bool(win32.GetMonitorInfoW(monitor, &info)) do return
		app.fullscreen = true
		app.controls_visible = false
		app.hover_started = {}
		win32.SetWindowLongPtrW(app.hwnd, win32.GWL_STYLE, app.windowed_style & ~win32.LONG_PTR(win32.WS_OVERLAPPEDWINDOW))
		target := win32.HWND_TOPMOST if app.always_on_top else win32.HWND_TOP
		win32.SetWindowPos(app.hwnd, target, info.rcMonitor.left, info.rcMonitor.top, info.rcMonitor.right-info.rcMonitor.left, info.rcMonitor.bottom-info.rcMonitor.top, win32.SWP_FRAMECHANGED | win32.SWP_NOOWNERZORDER)
		set_window_frame_appearance(app.hwnd, true)
	} else {
		app.fullscreen = false
		app.controls_visible = true
		app.hover_started = {}
		win32.SetWindowLongPtrW(app.hwnd, win32.GWL_STYLE, app.windowed_style)
		r := app.windowed_rect
		win32.SetWindowPos(app.hwnd, nil, r.left, r.top, r.right-r.left, r.bottom-r.top, win32.SWP_FRAMECHANGED | win32.SWP_NOZORDER | win32.SWP_NOOWNERZORDER)
		set_window_frame_appearance(app.hwnd, false)
	}
	win32.SetCursor(win32.LoadCursorA(nil, win32.IDC_ARROW))
		renderer_request_redraw(&app.renderer)
}

set_window_frame_appearance :: proc(hwnd: win32.HWND, fullscreen: bool) {
	// Windows 11 renders the physical window shape and the one-pixel outline.
	// Unsupported DWM attributes fail harmlessly on earlier Windows versions.
	corner := win32.DWM_WINDOW_CORNER_PREFERENCE.ROUND
	border_color := win32.COLORREF(0x00464646)
	if fullscreen {
		corner = .DONOTROUND
		border_color = win32.COLORREF(0xffff_fffe) // DWMWA_COLOR_NONE
	}
	win32.DwmSetWindowAttribute(
		hwnd,
		win32.DWORD(win32.DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE),
		&corner,
		win32.DWORD(size_of(corner)),
	)
	win32.DwmSetWindowAttribute(
		hwnd,
		win32.DWORD(win32.DWMWINDOWATTRIBUTE.DWMWA_BORDER_COLOR),
		&border_color,
		win32.DWORD(size_of(border_color)),
	)
}

fatal :: proc(message: string) {
	fmt.eprintln(message)
	wide := win32.utf8_to_utf16(message)
	win32.MessageBoxW(nil, cstring16(&wide[0]), cstring16(WINDOW_TITLE), win32.MB_OK | win32.MB_ICONERROR)
	win32.ExitProcess(1)
}
