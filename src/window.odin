package main

import "base:runtime"
import "core:sync"
import win32 "core:sys/windows"

// The window keeps a 16:9 video area below its title bar.
ASPECT_NUM   :: 16
ASPECT_DEN   :: 9
DEFAULT_VIDEO_WIDTH :: 1280
MIN_CLIENT_W :: 320
MIN_CLIENT_H :: 180

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
	case VIDEO_ENHANCEMENT_MESSAGE:
		renderer_request_redraw(&app.renderer)
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
			apply_ui_action(.FPS_Visible, 0)
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
