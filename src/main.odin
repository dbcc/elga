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
DEFAULT_VIDEO_WIDTH :: 1280
MIN_CLIENT_W :: 320
MIN_CLIENT_H :: 180
FRAME_ARENA_SIZE :: 64 * 1024
SCREENSHOT_FEEDBACK_DURATION :: 4*time.Second
UI_TIMER           :: 1
REDRAW_RETRY_TIMER  :: 2
UI_ACTION_MESSAGE   :: win32.WM_APP + 2
CAPTURE_FAILED_MESSAGE :: win32.WM_APP + 3
CAPTURE_READY_MESSAGE  :: win32.WM_APP + 4
EDID_RESULT_MESSAGE    :: win32.WM_APP + 5
ELGA_FULLSCREEN_STRESS :: #config(ELGA_FULLSCREEN_STRESS, false)
ELGA_FORMAT_STRESS     :: #config(ELGA_FORMAT_STRESS, false)

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
	// The custom title bar is persistent while windowed and hover-revealed in fullscreen.
	controls_visible: bool,
	hover_started:    time.Time,
	last_ui_tick:     time.Time,
	pinned_x:         i32,
	pinned_y:         i32,
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
	wake_init(&app.wake)
	win32.SetTimer(hwnd, UI_TIMER, 100, nil)

	win32.ShowWindow(hwnd, win32.SW_SHOW)
	win32.UpdateWindow(hwnd)

	msg: win32.MSG
	for win32.GetMessageW(&msg, nil, 0, 0) > 0 {
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
		if !app.renderer.ready do return 0
		if wparam == win32.SIZE_MINIMIZED {
			renderer_suspend_capture(&app.renderer)
		} else {
			renderer_request_resize(&app.renderer, u32(lparam & 0xffff), u32((lparam >> 16) & 0xffff))
		}
		return 0
	case win32.WM_TIMER:
		switch wparam {
		case UI_TIMER:
			ui_tick()
		case REDRAW_RETRY_TIMER:
			renderer_cancel_redraw_retry(&app.renderer)
			renderer_request_redraw(&app.renderer)
		}
		return 0
	case win32.WM_DPICHANGED:
		imgui_ui_set_dpi(&app.ui, u32(wparam & 0xffff))
		suggested := cast(^win32.RECT)uintptr(lparam)
		if !app.fullscreen && suggested != nil {
			win32.SetWindowPos(
				hwnd, nil,
				suggested.left, suggested.top,
				suggested.right-suggested.left, suggested.bottom-suggested.top,
				win32.SWP_NOZORDER | win32.SWP_NOACTIVATE,
			)
		}
		renderer_request_redraw(&app.renderer)
		return 0
	case win32.WM_NCCALCSIZE:
		if wparam == 0 do break
		// Returning zero makes the whole window client area and removes the
		// standard caption. Maximized windows retain the system resize inset
		// so the custom bar is not clipped beyond the monitor work area.
		if !app.fullscreen && win32.IsZoomed(hwnd) {
			params := cast(^win32.NCCALCSIZE_PARAMS)uintptr(lparam)
			border_x, border_y := resize_border(hwnd)
			params.rgrc[0].left += border_x
			params.rgrc[0].top += border_y
			params.rgrc[0].right -= border_x
			params.rgrc[0].bottom -= border_y
		}
		return 0
	case win32.WM_NCHITTEST:
		return hit_test(hwnd, lparam)
	case win32.WM_MOVING:
		if app.position_pin {
			pin_rect(cast(^win32.RECT)uintptr(lparam))
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
			enforce_16_9_for_dpi(r, u32(wparam), win32.GetDpiForWindow(hwnd))
			if app.position_pin do pin_rect(r)
			return 1
		}
	case win32.WM_KEYDOWN:
		// Ignore auto-repeat so a held key does not toggle repeatedly.
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
		save_window_layout(hwnd)
		return 0
	case win32.WM_CLOSE:
		save_window_layout(hwnd)
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

// Resize edges, the caption drag region, and client controls for the borderless window.
hit_test :: proc(hwnd: win32.HWND, lparam: win32.LPARAM) -> win32.LRESULT {
	if app.fullscreen do return win32.HTCLIENT
	point := win32.POINT{win32.GET_X_LPARAM(lparam), win32.GET_Y_LPARAM(lparam)}
	win32.ScreenToClient(hwnd, &point)
	client: win32.RECT
	win32.GetClientRect(hwnd, &client)
	if !win32.IsZoomed(hwnd) {
		border_x, border_y := resize_border(hwnd)
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
	s := dpi_scale(win32.GetDpiForWindow(hwnd))
	x, y := f32(point.x), f32(point.y)
	in_drag_region := x < TITLE_BAR_DRAG_WIDTH*s || (x >= title_bar_controls_end(s) && x < title_bar_wake_start(f32(client.right), s))
	if point.x >= 0 && point.y >= 0 && in_drag_region && y < TITLE_BAR_HEIGHT*s do return win32.HTCAPTION
	return win32.HTCLIENT
}

resize_border :: proc(hwnd: win32.HWND) -> (x, y: i32) {
	dpi := win32.GetDpiForWindow(hwnd)
	padding := win32.GetSystemMetricsForDpi(win32.SM_CXPADDEDBORDER, dpi)
	return win32.GetSystemMetricsForDpi(win32.SM_CXSIZEFRAME, dpi) + padding, win32.GetSystemMetricsForDpi(win32.SM_CYSIZEFRAME, dpi) + padding
}

// Keeps a pinned window's origin fixed while preserving the proposed size.
pin_rect :: proc(r: ^win32.RECT) {
	if r == nil do return
	r.right, r.bottom = app.pinned_x+r.right-r.left, app.pinned_y+r.bottom-r.top
	r.left, r.top = app.pinned_x, app.pinned_y
}

save_window_layout :: proc(hwnd: win32.HWND) {
	window_layout_observe(&app.layout, hwnd, app.fullscreen, app.always_on_top)
	window_layout_save(&app.layout)
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
	capture_health_update(&app.renderer)
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
	case .Reconnect:
		renderer_request_reconnect(&app.renderer)
	case .EDID_Mode:
		if value >= 0 && value < len(EDID_Mode) do renderer_request_edid_mode(&app.renderer, EDID_Mode(value))
	case .EDID_Refresh:
		renderer_request_edid_refresh(&app.renderer)
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
	case .ColorFormat:
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

// Debug builds only (-define:ELGA_FULLSCREEN_STRESS=true): twelve transitions, then exit.
fullscreen_stress_tick :: proc() {
	@(static) started: time.Time
	@(static) step: int
	if started == {} {
		started = time.now()
		return
	}
	target_step := min(int(time.duration_seconds(time.since(started))/0.5), 12)
	for step < target_step {
		toggle_fullscreen()
		step += 1
		fmt.eprintf("fullscreen stress transition %d/12\n", step)
	}
	if step >= 12 do win32.PostMessageW(app.hwnd, win32.WM_CLOSE, 0, 0)
}

// Debug builds only (-define:ELGA_FORMAT_STRESS=true): cycles resolutions and formats, then exits.
format_stress_tick :: proc() {
	@(static) started: time.Time
	@(static) step: int
	if started == {} {
		started = time.now()
		return
	}
	r := &app.renderer
	target_step := min(int(time.duration_seconds(time.since(started))/3.0), 8)
	for step < target_step {
		fmt.eprintf("mode stress state: %s %dx%d sequence=%d display=%.1f FPS\n", CAPTURE_FORMAT_NAME[r.capture_format], r.mode.width, r.mode.height, sync.atomic_load_explicit(&r.video_sequence, .Acquire), r.display_fps)
		switch step {
		case 0: renderer_set_capture_resolution(r, 1920, 1080)
		case 1: renderer_set_capture_resolution(r, 1280, 720)
		case 2: renderer_set_capture_resolution(r, 2560, 1440)
		case 3: renderer_set_capture_resolution(r, 0, 0)
		case 4: renderer_set_capture_format(r, .P010)
		case 5: renderer_set_capture_format(r, .YUY2)
		case 6: renderer_set_capture_format(r, .NV12)
		case 7: win32.PostMessageW(app.hwnd, win32.WM_CLOSE, 0, 0)
		}
		step += 1
		fmt.eprintf("mode stress transition %d/8\n", step)
	}
}

dpi_scale :: proc(dpi: u32) -> f32 {
	return max(f32(dpi)/f32(win32.USER_DEFAULT_SCREEN_DPI), 1.0)
}

title_bar_height_for_dpi :: proc(dpi: u32) -> i32 {
	// Match ImGui's minimum scale and round fractional rows up so the video
	// never shares a pixel with the bottom of the title bar.
	return (i32(TITLE_BAR_HEIGHT)*i32(max(dpi, win32.USER_DEFAULT_SCREEN_DPI)) + 95)/96
}

// The default 1280x720 video area plus the title bar, in physical pixels.
default_window_size :: proc(dpi: u32) -> (width, height: i32) {
	width = DEFAULT_VIDEO_WIDTH*i32(dpi)/win32.USER_DEFAULT_SCREEN_DPI
	height = (DEFAULT_VIDEO_WIDTH*ASPECT_DEN/ASPECT_NUM)*i32(dpi)/win32.USER_DEFAULT_SCREEN_DPI + title_bar_height_for_dpi(dpi)
	return
}

enforce_16_9_for_dpi :: proc(rect: ^win32.RECT, edge, dpi: u32) {
	if rect == nil do return
	bar_height := title_bar_height_for_dpi(dpi)
	minimum_width := MIN_CLIENT_W*i32(dpi)/i32(win32.USER_DEFAULT_SCREEN_DPI)
	minimum_height := MIN_CLIENT_H*i32(dpi)/i32(win32.USER_DEFAULT_SCREEN_DPI)
	client_w := max(rect.right-rect.left, minimum_width)
	client_h := max(rect.bottom-rect.top-bar_height, minimum_height)

	// Vertical edges follow height; horizontal edges and corners follow width.
	// Comparing aspect-ratio errors always favors width because 16/9 > 1.
	if edge != win32.WMSZ_TOP && edge != win32.WMSZ_BOTTOM {
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
		win32.SetWindowLongPtrW(app.hwnd, win32.GWL_STYLE, app.windowed_style & ~win32.LONG_PTR(win32.WS_OVERLAPPEDWINDOW))
		target := win32.HWND_TOPMOST if app.always_on_top else win32.HWND_TOP
		m := info.rcMonitor
		win32.SetWindowPos(app.hwnd, target, m.left, m.top, m.right-m.left, m.bottom-m.top, win32.SWP_FRAMECHANGED | win32.SWP_NOOWNERZORDER)
	} else {
		app.fullscreen = false
		app.controls_visible = true
		win32.SetWindowLongPtrW(app.hwnd, win32.GWL_STYLE, app.windowed_style)
		r := app.windowed_rect
		win32.SetWindowPos(app.hwnd, nil, r.left, r.top, r.right-r.left, r.bottom-r.top, win32.SWP_FRAMECHANGED | win32.SWP_NOZORDER | win32.SWP_NOOWNERZORDER)
	}
	app.hover_started = {}
	set_window_frame_appearance(app.hwnd, app.fullscreen)
	win32.SetCursor(win32.LoadCursorA(nil, win32.IDC_ARROW))
	renderer_request_redraw(&app.renderer)
}

set_window_frame_appearance :: proc(hwnd: win32.HWND, fullscreen: bool) {
	// Windows 11 renders the physical window shape and the one-pixel outline.
	// Unsupported DWM attributes fail harmlessly on earlier Windows versions.
	corner := win32.DWM_WINDOW_CORNER_PREFERENCE.DONOTROUND if fullscreen else .ROUND
	border_color := win32.COLORREF(0xffff_fffe if fullscreen else 0x00464646) // 0xfffffffe is DWMWA_COLOR_NONE
	win32.DwmSetWindowAttribute(hwnd, win32.DWORD(win32.DWMWINDOWATTRIBUTE.DWMWA_WINDOW_CORNER_PREFERENCE), &corner, win32.DWORD(size_of(corner)))
	win32.DwmSetWindowAttribute(hwnd, win32.DWORD(win32.DWMWINDOWATTRIBUTE.DWMWA_BORDER_COLOR), &border_color, win32.DWORD(size_of(border_color)))
}

fatal :: proc(message: string) {
	fmt.eprintln(message)
	wide := win32.utf8_to_utf16(message)
	win32.MessageBoxW(nil, cstring16(&wide[0]), cstring16(WINDOW_TITLE), win32.MB_OK | win32.MB_ICONERROR)
	win32.ExitProcess(1)
}
