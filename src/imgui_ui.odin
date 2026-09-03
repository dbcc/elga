package main

import "core:time"
import "core:fmt"
import "core:sync"
import win32 "core:sys/windows"
import imgui "../vendor/odin-imgui"
import imgui_dx11 "../vendor/odin-imgui/imgui_impl_dx11"

UI_FONT_SIZE            :: 16.0
UI_ICON_BUTTON_SIZE     :: 28.0
UI_ICON_SCALE           :: 0.82
TITLE_BAR_HEIGHT        :: 42.0
TITLE_BAR_DRAG_WIDTH    :: 72.0
TITLE_BAR_BUTTON_WIDTH  :: 40.0
TITLE_BAR_ITEM_SPACING  :: 6.0

Control_Icon :: enum {
	Fullscreen,
	Pin,
	Topmost,
	Audio,
	Muted,
	Wake,
	Color,
	Mode,
	Minimize,
	Maximize,
	Restore,
	Close,
}

TITLE_BAR_WINDOW_FLAGS :: imgui.WindowFlags_NoDecoration | imgui.WindowFlags {
	.NoMove, .NoSavedSettings, .NoFocusOnAppearing,
	.NoNavInputs, .NoNavFocus, .NoDocking,
}

ImGui_State :: struct {
	ready: bool,
	menu_open: bool,
	last_frame: time.Time,
	mouse_pos: imgui.Vec2,
	mouse_dirty: bool,
	dpi_scale: f32,
	font: ^imgui.Font,
	font_size: f32,
}

imgui_ui_init :: proc(ui: ^ImGui_State, r: ^Renderer) -> bool {
	imgui.CreateContext()
	io := imgui.GetIO()
	io.IniFilename = nil
	io.LogFilename = nil
	ui.dpi_scale = max(f32(win32.GetDpiForWindow(r.hwnd))/f32(win32.USER_DEFAULT_SCREEN_DPI), 1.0)
	ui.font_size = UI_FONT_SIZE*ui.dpi_scale
	ui.font = imgui.FontAtlas_AddFontDefaultVector(io.Fonts)
	if ui.font == nil {
		imgui.DestroyContext()
		return false
	}
	io.FontDefault = ui.font
	imgui.StyleColorsDark()
	style := imgui.GetStyle()
	style.WindowRounding = 7
	style.PopupRounding = 7
	style.FrameRounding = 5
	style.WindowBorderSize = 0
	style.FrameBorderSize = 0
	style.WindowPadding = {8, 8}
	style.FramePadding = {10, 6}
	style.ItemSpacing = {TITLE_BAR_ITEM_SPACING, 6}
	imgui.Style_ScaleAllSizes(style, ui.dpi_scale)

	if !imgui_dx11.Init(r.device_11, r.context_11) {
		imgui.DestroyContext()
		return false
	}
	ui.ready = true
	ui.last_frame = time.now()
	return true
}

imgui_ui_destroy :: proc(ui: ^ImGui_State) {
	if ui.ready {
		imgui_dx11.Shutdown()
		imgui.DestroyContext()
		ui.ready = false
	}
}

imgui_ui_set_dpi :: proc(ui: ^ImGui_State, dpi: u32) {
	new_scale := max(f32(dpi)/f32(win32.USER_DEFAULT_SCREEN_DPI), 1.0)
	old_scale := max(ui.dpi_scale, 1.0)
	if abs(new_scale-old_scale) < 0.001 do return
	ui.dpi_scale = new_scale
	ui.font_size = UI_FONT_SIZE*new_scale
	if ui.ready {
		imgui.Style_ScaleAllSizes(imgui.GetStyle(), new_scale/old_scale)
	}
}

imgui_ui_new_frame :: proc(ui: ^ImGui_State, r: ^Renderer) -> ^imgui.DrawData {
	if !ui.ready do return nil
	now := time.now()
	delta := f32(time.duration_seconds(time.since(ui.last_frame)))
	ui.last_frame = now
	if delta <= 0 || delta > 0.25 do delta = 1.0/60.0

	io := imgui.GetIO()
	io.DisplaySize = {f32(r.width), f32(r.height)}
	io.DisplayFramebufferScale = {1, 1}
	io.DeltaTime = delta
	if ui.mouse_dirty {
		imgui.IO_AddMousePosEvent(io, ui.mouse_pos.x, ui.mouse_pos.y)
		ui.mouse_dirty = false
	}

	imgui_dx11.NewFrame()
	imgui.NewFrame()
	imgui.PushFontFloat(ui.font, ui.font_size)
	imgui_build_overlay(ui, r)
	imgui.PopFont()
	imgui.Render()
	return imgui.GetDrawData()
}

imgui_ui_render :: proc(ui: ^ImGui_State, draw_data: ^imgui.DrawData) {
	if !ui.ready || draw_data == nil do return
	imgui_dx11.RenderDrawData(draw_data)
}

imgui_build_overlay :: proc(ui: ^ImGui_State, r: ^Renderer) {
	ui.menu_open = false
	if app.controls_visible {
		s := ui.dpi_scale
		logical_width := f32(r.width)/s
		compact := logical_width < 520
		imgui.PushStyleVar(.WindowRounding, 0)
		imgui.PushStyleVar(.FrameRounding, 0)
		imgui.PushStyleColorImVec4(.WindowBg, {0.018, 0.018, 0.018, 1})
		imgui.PushStyleColorImVec4(.Button, {0, 0, 0, 0})
		imgui.PushStyleColorImVec4(.ButtonHovered, {0.13, 0.13, 0.13, 1})
		imgui.PushStyleColorImVec4(.ButtonActive, {0.20, 0.20, 0.20, 1})
		imgui.PushStyleColorImVec4(.Text, {0.82, 0.84, 0.87, 1})
		imgui.SetNextWindowPos({0, 0}, .Always)
		imgui.SetNextWindowSize({f32(r.width), TITLE_BAR_HEIGHT*s}, .Always)
		imgui.SetNextWindowBgAlpha(1)
		imgui.Begin("##custom_title_bar", nil, TITLE_BAR_WINDOW_FLAGS)
		title_draw := imgui.GetWindowDrawList()
		outline := imgui.ColorConvertFloat4ToU32({0.28, 0.29, 0.31, 1})
		separator := imgui.ColorConvertFloat4ToU32({0.24, 0.25, 0.27, 1})
		imgui.DrawList_AddLine(title_draw, {0, TITLE_BAR_HEIGHT*s-0.5*s}, {f32(r.width), TITLE_BAR_HEIGHT*s-0.5*s}, outline, 1*s)
		imgui.DrawList_AddLine(title_draw, {60*s, 10*s}, {60*s, 32*s}, separator, 1*s)

		imgui.SetCursorPos({10*s, 6*s})
		imgui.AlignTextToFramePadding()
		imgui.TextUnformatted("ELGA")
		imgui.SetCursorPos({TITLE_BAR_DRAG_WIDTH*s, 7*s})
		if icon_button(ui, "##fullscreen", .Fullscreen) do post_ui_action(.Fullscreen)
		imgui.SetItemTooltipUnformatted("Exit fullscreen (F)" if app.fullscreen else "Fullscreen (F)")
		if !compact {
			imgui.SameLine()
			if icon_button(ui, "##pin", .Pin, app.position_pin) do post_ui_action(.Pin)
			imgui.SetItemTooltipUnformatted("Unpin window position" if app.position_pin else "Pin the current window position")
			imgui.SameLine()
			if icon_button(ui, "##top", .Topmost, app.always_on_top) do post_ui_action(.Topmost)
			imgui.SetItemTooltipUnformatted("Disable always on top" if app.always_on_top else "Always on top")
		}
		imgui.SameLine()
		muted := audio_is_muted(&app.audio)
		if icon_button(ui, "##audio", .Muted if muted else .Audio, muted) do post_ui_action(.Audio)
		imgui.SetItemTooltipUnformatted("Left-click: mute. Right-click: select output device")
		if imgui.BeginPopupContextItem("audio_outputs", imgui.PopupFlags_MouseButtonRight) {
			ui.menu_open = true
			if imgui.Selectable("Windows default output", app.audio.selected_output < 0) {
				post_ui_action(.Output, 0)
			}
			for i in 0..<app.audio.output_count {
				name := cstring(&app.audio.outputs[i].name[0])
				if imgui.Selectable(name, app.audio.selected_output == i) {
					post_ui_action(.Output, i+1)
				}
			}
			imgui.EndPopup()
		}
		imgui.SameLine()
		wake_status := wake_get_status(&app.wake)
		if icon_button(ui, "##wake_switch", .Wake, wake_status == .Sending || wake_status == .Success) do post_ui_action(.Wake)
		switch wake_status {
		case .Unavailable:
			if wake_get_error(&app.wake) == .Curl_Global_Init {
				imgui.SetItemTooltipUnformatted("Switch wake is unavailable: libcurl initialization failed")
			} else {
				imgui.SetItemTooltipUnformatted("Switch wake is unavailable")
			}
		case .Sending:     imgui.SetItemTooltipUnformatted("Sending Switch 2 wake request...")
		case .Success:     imgui.SetItemTooltipUnformatted("Switch 2 wake request sent")
		case .Failed:
			switch wake_get_error(&app.wake) {
			case .Thread_Create:  imgui.SetItemTooltipUnformatted("Switch wake failed: could not create worker thread")
			case .Curl_Easy_Init: imgui.SetItemTooltipUnformatted("Switch wake failed: could not create curl request")
			case .Curl_Setup:     imgui.SetItemTooltipUnformatted("Switch wake failed: could not configure curl")
			case .Resolve:        imgui.SetItemTooltipUnformatted("Switch wake failed: could not resolve switch2-waker.local")
			case .Connect:        imgui.SetItemTooltipUnformatted("Switch wake failed: beacon refused the connection")
			case .Timeout:        imgui.SetItemTooltipUnformatted("Switch wake failed: beacon timed out")
			case .Http:           imgui.SetItemTooltip("Switch wake failed: beacon returned HTTP %u", wake_get_http_status(&app.wake))
			case .Cancelled:      imgui.SetItemTooltipUnformatted("Switch wake request was cancelled")
			case .None, .Curl_Global_Init, .Transfer:
				imgui.SetItemTooltipUnformatted("Switch wake failed during transfer")
			}
		case .Idle:        imgui.SetItemTooltipUnformatted("Wake Nintendo Switch 2")
		}

		if !compact {
			imgui.SameLine()
			if icon_button(ui, "##color", .Color) do imgui.OpenPopup("color_settings")
			imgui.SetItemTooltipUnformatted("Capture source format; compatibility formats are converted to a GPU display format by Windows Media Foundation")
			if imgui.BeginPopup("color_settings") {
				ui.menu_open = true
				imgui.SeparatorText("Capture source format")
				if imgui.MenuItem("Auto - match native mode", nil, r.format_auto) {
					post_ui_action(.ColorFormat, CAPTURE_FORMAT_COUNT)
				}
				for raw_format in 0..<CAPTURE_FORMAT_COUNT {
					format := Capture_Format(raw_format)
					available := capture_format_available(r, format)
					if !available do continue
					if imgui.MenuItem(capture_format_menu_label(format), nil, !r.format_auto && r.capture_format == format) {
						post_ui_action(.ColorFormat, raw_format)
					}
				}
				imgui.TextDisabledUnformatted("I420/MJPEG use NV12; RGB24 is expanded to 32-bit RGB")
				imgui.SeparatorText("Color")
				imgui.TextDisabledUnformatted("Native Windows GPU conversion from 4K X YUV")
				imgui.TextDisabledUnformatted("The app does not adjust color or the 4K X range")
				imgui.EndPopup()
			}

			imgui.SameLine()
			if icon_button(ui, "##mode", .Mode) do imgui.OpenPopup("capture_modes")
			imgui.SetItemTooltipUnformatted("Capture resolution; highest available FPS is selected")
			if imgui.BeginPopup("capture_modes") {
				ui.menu_open = true
				imgui.SeparatorText(capture_format_selection_ui_name(r))
				if imgui.MenuItem("Auto - highest resolution", nil, r.requested_width == 0) {
					post_ui_action(.Resolution, 0)
				}
				count := int(sync.atomic_load_explicit(&r.capture_mode_count, .Acquire))
				last_width, last_height: u32
				for i in 0..<count {
					mode := capture_mode_at(r, i)
					if mode.width == last_width && mode.height == last_height do continue
					last_width, last_height = mode.width, mode.height
					label := fmt.ctprintf("%dx%d", mode.width, mode.height)
					selected := r.requested_width == mode.width && r.requested_height == mode.height
					if imgui.MenuItem(label, nil, selected) {
						packed := int(u64(mode.width)<<32 | u64(mode.height))
						post_ui_action(.Resolution, packed)
					}
				}
				imgui.EndPopup()
			}
		}

		if logical_width >= 760 {
			imgui.SameLine(0, 14*s)
			status_pos := imgui.GetCursorPos()
			status_color := imgui.ColorConvertFloat4ToU32({0.35, 0.82, 0.55, 1})
			capture_ready := sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0
			capture_running := sync.atomic_load_explicit(&r.capture_running, .Acquire)
			if !capture_ready {
				status_color = imgui.ColorConvertFloat4ToU32({0.95, 0.66, 0.25, 1}) if capture_running else imgui.ColorConvertFloat4ToU32({0.90, 0.25, 0.25, 1})
			}
			imgui.DrawList_AddCircleFilled(title_draw, {status_pos.x+4*s, TITLE_BAR_HEIGHT*s*0.5}, 3*s, status_color, 12)
			imgui.SetCursorPosX(status_pos.x+13*s)
			imgui.AlignTextToFramePadding()
			if capture_ready {
				if app.fps_visible && logical_width >= 1050 {
					imgui.Text("%ux%u @ %.1f  /  %s  /  %.1f display FPS", r.capture_width, r.capture_height, f64(r.capture_fps_num)/f64(r.capture_fps_den), capture_format_selection_ui_name(r), r.display_fps)
				} else if app.fps_visible {
					imgui.Text("%ux%u  /  %.1f display FPS", r.capture_width, r.capture_height, r.display_fps)
				} else {
					imgui.Text("%ux%u @ %.1f  /  %s", r.capture_width, r.capture_height, f64(r.capture_fps_num)/f64(r.capture_fps_den), capture_format_selection_ui_name(r))
				}
			} else if capture_running {
				imgui.Text("Elgato 4K X  /  connecting %s", capture_format_selection_ui_name(r))
			} else {
				imgui.Text("Elgato 4K X  /  capture unavailable")
			}
		}

		// Keep the standard window commands fixed to the right edge, independent
		// of which capture controls or status text fit in the middle.
		button_x := f32(r.width) - 3*TITLE_BAR_BUTTON_WIDTH*s
		imgui.SetCursorPos({button_x, 0})
		if title_bar_button(ui, "##minimize", .Minimize) do post_ui_action(.Minimize)
		imgui.SetItemTooltipUnformatted("Minimize")
		imgui.SameLine(0, 0)
		maximized := app.fullscreen || win32.IsZoomed(app.hwnd)
		if title_bar_button(ui, "##maximize", .Restore if maximized else .Maximize) do post_ui_action(.Maximize)
		imgui.SetItemTooltipUnformatted("Restore" if maximized else "Maximize")
		imgui.SameLine(0, 0)
		if title_bar_button(ui, "##close", .Close) do post_ui_action(.Close)
		imgui.SetItemTooltipUnformatted("Close")
		imgui.End()
		imgui.PopStyleColor(5)
		imgui.PopStyleVar(2)
	}
}

icon_button :: proc(ui: ^ImGui_State, id: cstring, icon: Control_Icon, active := false) -> bool {
	size := UI_ICON_BUTTON_SIZE*ui.dpi_scale
	imgui.PushStyleVar(.FrameRounding, 5*ui.dpi_scale)
	clicked := imgui.Button(id, {size, size})
	imgui.PopStyleVar()
	icon_min, icon_max := imgui.GetItemRectMin(), imgui.GetItemRectMax()
	color := imgui.GetColorU32(.CheckMark if active else .Text)
	draw_control_icon(imgui.GetWindowDrawList(), icon, icon_min, icon_max, color, ui.dpi_scale*UI_ICON_SCALE)
	return clicked
}

title_bar_button :: proc(ui: ^ImGui_State, id: cstring, icon: Control_Icon) -> bool {
	if icon == .Close {
		imgui.PushStyleColorImVec4(.ButtonHovered, {0.78, 0.10, 0.12, 1})
		imgui.PushStyleColorImVec4(.ButtonActive, {0.58, 0.06, 0.08, 1})
	}
	clicked := imgui.Button(id, {TITLE_BAR_BUTTON_WIDTH*ui.dpi_scale, TITLE_BAR_HEIGHT*ui.dpi_scale})
	draw_control_icon(imgui.GetWindowDrawList(), icon, imgui.GetItemRectMin(), imgui.GetItemRectMax(), imgui.GetColorU32(.Text), ui.dpi_scale*UI_ICON_SCALE)
	if icon == .Close do imgui.PopStyleColor(2)
	return clicked
}

draw_control_icon :: proc(draw: ^imgui.DrawList, icon: Control_Icon, min, max: imgui.Vec2, color: u32, scale: f32) {
	c := imgui.Vec2{(min.x+max.x)*0.5, (min.y+max.y)*0.5}
	s := scale
	stroke := 1.75*s
	switch icon {
	case .Fullscreen:
		left, right := c.x-9*s, c.x+9*s
		top, bottom := c.y-9*s, c.y+9*s
		leg := 6*s
		imgui.DrawList_AddLine(draw, {left, top+leg}, {left, top}, color, stroke)
		imgui.DrawList_AddLine(draw, {left, top}, {left+leg, top}, color, stroke)
		imgui.DrawList_AddLine(draw, {right-leg, top}, {right, top}, color, stroke)
		imgui.DrawList_AddLine(draw, {right, top}, {right, top+leg}, color, stroke)
		imgui.DrawList_AddLine(draw, {left, bottom-leg}, {left, bottom}, color, stroke)
		imgui.DrawList_AddLine(draw, {left, bottom}, {left+leg, bottom}, color, stroke)
		imgui.DrawList_AddLine(draw, {right-leg, bottom}, {right, bottom}, color, stroke)
		imgui.DrawList_AddLine(draw, {right, bottom}, {right, bottom-leg}, color, stroke)
	case .Pin:
		imgui.DrawList_AddLine(draw, {c.x-7*s, c.y-7*s}, {c.x+7*s, c.y-7*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x-5*s, c.y-7*s}, {c.x-4*s, c.y-1*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x+5*s, c.y-7*s}, {c.x+4*s, c.y-1*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x-7*s, c.y-1*s}, {c.x+7*s, c.y-1*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x-4*s, c.y-1*s}, {c.x, c.y+3*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x+4*s, c.y-1*s}, {c.x, c.y+3*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x, c.y+3*s}, {c.x, c.y+10*s}, color, stroke)
	case .Topmost:
		imgui.DrawList_AddRect(draw, {c.x-9*s, c.y-3*s}, {c.x+9*s, c.y+9*s}, color, 1.5*s, stroke)
		imgui.DrawList_AddLine(draw, {c.x, c.y+4*s}, {c.x, c.y-9*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x, c.y-9*s}, {c.x-5*s, c.y-4*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x, c.y-9*s}, {c.x+5*s, c.y-4*s}, color, stroke)
	case .Audio, .Muted:
		imgui.DrawList_PathLineTo(draw, {c.x-10*s, c.y-4*s})
		imgui.DrawList_PathLineTo(draw, {c.x-5*s, c.y-4*s})
		imgui.DrawList_PathLineTo(draw, {c.x+1*s, c.y-9*s})
		imgui.DrawList_PathLineTo(draw, {c.x+1*s, c.y+9*s})
		imgui.DrawList_PathLineTo(draw, {c.x-5*s, c.y+4*s})
		imgui.DrawList_PathLineTo(draw, {c.x-10*s, c.y+4*s})
		imgui.DrawList_PathFillConvex(draw, color)
		if icon == .Muted {
			imgui.DrawList_AddLine(draw, {c.x+6*s, c.y-5*s}, {c.x+13*s, c.y+5*s}, color, stroke)
			imgui.DrawList_AddLine(draw, {c.x+13*s, c.y-5*s}, {c.x+6*s, c.y+5*s}, color, stroke)
		} else {
			imgui.DrawList_PathArcTo(draw, {c.x+1*s, c.y}, 7*s, -0.75, 0.75, 8)
			imgui.DrawList_PathStroke(draw, color, stroke)
			imgui.DrawList_PathArcTo(draw, {c.x+1*s, c.y}, 12*s, -0.65, 0.65, 8)
			imgui.DrawList_PathStroke(draw, color, stroke)
		}
	case .Wake:
		imgui.DrawList_PathArcTo(draw, c, 9*s, -0.75, 3.89, 20)
		imgui.DrawList_PathStroke(draw, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x, c.y-11*s}, {c.x, c.y-1*s}, color, stroke)
	case .Color:
		red := imgui.ColorConvertFloat4ToU32({0.95, 0.30, 0.27, 1})
		green := imgui.ColorConvertFloat4ToU32({0.30, 0.85, 0.48, 1})
		blue := imgui.ColorConvertFloat4ToU32({0.30, 0.58, 1.00, 1})
		imgui.DrawList_AddCircleFilled(draw, {c.x, c.y-5*s}, 5.5*s, red, 16)
		imgui.DrawList_AddCircleFilled(draw, {c.x-5*s, c.y+4*s}, 5.5*s, green, 16)
		imgui.DrawList_AddCircleFilled(draw, {c.x+5*s, c.y+4*s}, 5.5*s, blue, 16)
	case .Mode:
		imgui.DrawList_AddRect(draw, {c.x-11*s, c.y-8*s}, {c.x+11*s, c.y+7*s}, color, 2*s, stroke)
		imgui.DrawList_AddLine(draw, {c.x-5*s, c.y+11*s}, {c.x+5*s, c.y+11*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x, c.y+7*s}, {c.x, c.y+11*s}, color, stroke)
	case .Minimize:
		imgui.DrawList_AddLine(draw, {c.x-7*s, c.y+5*s}, {c.x+7*s, c.y+5*s}, color, stroke)
	case .Maximize:
		imgui.DrawList_AddRect(draw, {c.x-7*s, c.y-7*s}, {c.x+7*s, c.y+7*s}, color, 0, stroke)
	case .Restore:
		imgui.DrawList_AddRect(draw, {c.x-5*s, c.y-7*s}, {c.x+7*s, c.y+5*s}, color, 0, stroke)
		imgui.DrawList_AddRect(draw, {c.x-8*s, c.y-4*s}, {c.x+4*s, c.y+8*s}, color, 0, stroke)
	case .Close:
		imgui.DrawList_AddLine(draw, {c.x-7*s, c.y-7*s}, {c.x+7*s, c.y+7*s}, color, stroke)
		imgui.DrawList_AddLine(draw, {c.x+7*s, c.y-7*s}, {c.x-7*s, c.y+7*s}, color, stroke)
	}
}

capture_format_selection_ui_name :: proc(r: ^Renderer) -> cstring {
	if !r.format_auto do return capture_format_name(r.capture_format)
	switch r.capture_format {
	case .NV12: return "Auto (NV12)"
	case .P010: return "Auto (P010)"
	case .YUY2: return "Auto (YUY2)"
	case .I420: return "Auto (I420)"
	case .RGB24: return "Auto (RGB24)"
	case .MJPEG: return "Auto (MJPEG)"
	}
	return "Auto"
}

imgui_ui_process_message :: proc(ui: ^ImGui_State, hwnd: win32.HWND, msg: win32.UINT, wparam: win32.WPARAM, lparam: win32.LPARAM) {
	if !ui.ready do return
	if msg == win32.WM_MOUSEMOVE {
		ui.mouse_pos = {f32(win32.GET_X_LPARAM(lparam)), f32(win32.GET_Y_LPARAM(lparam))}
		ui.mouse_dirty = true
	}
	// Do not accumulate stale canvas clicks while ImGui is completely hidden.
	// Mouse movement is retained separately for the next visible frame.
	if !app.controls_visible && !ui.menu_open && msg != win32.WM_SETFOCUS && msg != win32.WM_KILLFOCUS do return
	io := imgui.GetIO()
	switch msg {
	case win32.WM_LBUTTONDOWN, win32.WM_LBUTTONDBLCLK:
		imgui.IO_AddMouseButtonEvent(io, 0, true)
		win32.SetCapture(hwnd)
	case win32.WM_LBUTTONUP:
		imgui.IO_AddMouseButtonEvent(io, 0, false)
		win32.ReleaseCapture()
	case win32.WM_RBUTTONDOWN, win32.WM_RBUTTONDBLCLK:
		imgui.IO_AddMouseButtonEvent(io, 1, true)
		win32.SetCapture(hwnd)
	case win32.WM_RBUTTONUP:
		imgui.IO_AddMouseButtonEvent(io, 1, false)
		win32.ReleaseCapture()
	case win32.WM_MBUTTONDOWN, win32.WM_MBUTTONDBLCLK:
		imgui.IO_AddMouseButtonEvent(io, 2, true)
		win32.SetCapture(hwnd)
	case win32.WM_MBUTTONUP:
		imgui.IO_AddMouseButtonEvent(io, 2, false)
		win32.ReleaseCapture()
	case win32.WM_MOUSEWHEEL:
		imgui.IO_AddMouseWheelEvent(io, 0, f32(win32.GET_WHEEL_DELTA_WPARAM(wparam))/f32(win32.WHEEL_DELTA))
	case win32.WM_MOUSEHWHEEL:
		imgui.IO_AddMouseWheelEvent(io, f32(win32.GET_WHEEL_DELTA_WPARAM(wparam))/f32(win32.WHEEL_DELTA), 0)
	case win32.WM_SETFOCUS:
		imgui.IO_AddFocusEvent(io, true)
	case win32.WM_KILLFOCUS:
		imgui.IO_AddFocusEvent(io, false)
	}
}
