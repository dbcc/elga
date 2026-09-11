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
TITLE_BAR_DRAG_WIDTH    :: 64.0
TITLE_BAR_BUTTON_WIDTH  :: 40.0
TITLE_BAR_ITEM_SPACING  :: 6.0
AUDIO_VOLUME_HOVER_DELAY :: 0.30
AUDIO_VOLUME_LEAVE_DELAY :: 0.25
AUDIO_VOLUME_FLYOUT_WIDTH :: 220.0

Control_Icon :: enum {
	Fullscreen,
	Pin,
	Topmost,
	Audio,
	Muted,
	Wake,
	Color,
	Mode,
	Settings,
	Minimize,
	Maximize,
	Restore,
	Close,
}

TITLE_BAR_WINDOW_FLAGS :: imgui.WindowFlags_NoDecoration | imgui.WindowFlags {
	.NoMove, .NoSavedSettings, .NoFocusOnAppearing,
	.NoNavInputs, .NoNavFocus, .NoDocking,
}

AUDIO_VOLUME_WINDOW_FLAGS :: imgui.WindowFlags_NoDecoration | imgui.WindowFlags {
	.NoMove, .NoSavedSettings, .NoFocusOnAppearing,
	.NoNavFocus, .NoDocking,
}

ImGui_State :: struct {
	ready: bool,
	menu_open: bool,
	last_frame: time.Time,
	mouse_pos: imgui.Vec2,
	mouse_dirty: bool,
	mouse_tracking: bool,
	focus_dirty: bool,
	focus_lost: bool,
	focused: bool,
	dpi_scale: f32,
	font: ^imgui.Font,
	font_size: f32,
	audio_volume_open: bool,
	audio_hover_started: f64,
	audio_leave_started: f64,
	edid_menu_open: bool,
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
	style.Colors[imgui.Col.PopupBg] = {0.035, 0.035, 0.035, 1}
	style.Colors[imgui.Col.Border] = {0.18, 0.18, 0.18, 1}
	style.Colors[imgui.Col.HeaderHovered] = {0.13, 0.13, 0.13, 1}
	style.Colors[imgui.Col.HeaderActive] = {0.20, 0.20, 0.20, 1}
	style.Colors[imgui.Col.CheckMark] = {0.74, 0.76, 0.78, 1}
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
	imgui_ui_flush_mouse_position(ui, io)

	imgui_dx11.NewFrame()
	imgui.NewFrame()
	imgui.PushFontFloat(ui.font, ui.font_size)
	imgui_build_overlay(ui, r)
	imgui_build_capture_feedback(ui, r)
	imgui.PopFont()
	imgui.Render()
	return imgui.GetDrawData()
}

imgui_ui_render :: proc(ui: ^ImGui_State, draw_data: ^imgui.DrawData) {
	if !ui.ready || draw_data == nil do return
	imgui_dx11.RenderDrawData(draw_data)
}

title_bar_controls_end :: proc(dpi_scale: f32) -> f32 {
	return (TITLE_BAR_DRAG_WIDTH + 3*UI_ICON_BUTTON_SIZE + 2*TITLE_BAR_ITEM_SPACING)*dpi_scale
}

title_bar_wake_start :: proc(client_width, dpi_scale: f32) -> f32 {
	return client_width - (3*TITLE_BAR_BUTTON_WIDTH + UI_ICON_BUTTON_SIZE + TITLE_BAR_ITEM_SPACING)*dpi_scale
}

imgui_build_overlay :: proc(ui: ^ImGui_State, r: ^Renderer) {
	ui.menu_open = false
	if app.controls_visible {
		s := ui.dpi_scale
		audio_button_hovered := false
		audio_output_menu_open := false
		audio_button_min, audio_button_max: imgui.Vec2
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
		outline := imgui.ColorConvertFloat4ToU32({0.14, 0.14, 0.14, 1})
		imgui.DrawList_AddLine(title_draw, {0, TITLE_BAR_HEIGHT*s-0.5*s}, {f32(r.width), TITLE_BAR_HEIGHT*s-0.5*s}, outline, 1*s)

		imgui.SetCursorPos({10*s, 6*s})
		imgui.AlignTextToFramePadding()
		imgui.TextUnformatted("ELGA")
		imgui.SetCursorPos({TITLE_BAR_DRAG_WIDTH*s, 7*s})
		if icon_button(ui, "##fullscreen", .Fullscreen) do post_ui_action(.Fullscreen)
		imgui.SetItemTooltipUnformatted("Exit fullscreen (F)" if app.fullscreen else "Fullscreen (F)")
		imgui.SameLine()
		muted := audio_is_muted(&app.audio)
		if icon_button(ui, "##audio", .Muted if muted else .Audio, muted) do post_ui_action(.Audio)
		audio_button_hovered = imgui.IsItemHovered()
		audio_button_min = imgui.GetItemRectMin()
		audio_button_max = imgui.GetItemRectMax()
		now := imgui.GetTime()
		if audio_button_hovered {
			ui.audio_leave_started = 0
			if !ui.audio_volume_open {
				if ui.audio_hover_started == 0 do ui.audio_hover_started = now
				if now-ui.audio_hover_started >= AUDIO_VOLUME_HOVER_DELAY do ui.audio_volume_open = true
			}
		} else if !ui.audio_volume_open {
			ui.audio_hover_started = 0
		}
		if !ui.audio_volume_open {
			imgui.SetItemTooltipUnformatted("Left-click: mute. Right-click: select output device")
		}
		if imgui.BeginPopupContextItem("audio_outputs", imgui.PopupFlags_MouseButtonRight) {
			ui.menu_open = true
			audio_output_menu_open = true
			ui.audio_volume_open = false
			ui.audio_hover_started = 0
			ui.audio_leave_started = 0
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
		if icon_button(ui, "##settings", .Settings) {
			ui.audio_volume_open = false
			ui.audio_hover_started = 0
			imgui.OpenPopup("settings")
		}
		imgui.SetItemTooltipUnformatted("Settings")
		imgui_build_settings(ui, r)

		// Keep the standard window commands fixed to the right edge, independent
		// of which capture controls or status text fit in the middle.
		button_x := f32(r.width) - 3*TITLE_BAR_BUTTON_WIDTH*s
		wake_x := title_bar_wake_start(f32(r.width), s)
		imgui_draw_capture_status(ui, r, title_draw, title_bar_controls_end(s)+16*s, wake_x-14*s)
		imgui.SetCursorPos({wake_x, 7*s})
		wake_status := wake_get_status(&app.wake)
		wake_online := wake_is_online(&app.wake)
		wake_disabled := !wake_online || wake_status == .Sending || wake_request_in_flight(&app.wake)
		imgui.BeginDisabled(wake_disabled)
		if icon_button(ui, "##wake_switch", .Wake, wake_status == .Sending || wake_status == .Success) do post_ui_action(.Wake)
		imgui.EndDisabled()
		if imgui.IsItemHovered(imgui.HoveredFlags_ForTooltip | imgui.HoveredFlags_AllowWhenDisabled) {
			wake_set_tooltip(&app.wake, wake_status, wake_online)
		}
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

		if ui.audio_volume_open && !audio_output_menu_open {
			audio_volume_flyout(ui, audio_button_min, audio_button_max, audio_button_hovered)
		}
	} else {
		ui.audio_volume_open = false
		ui.audio_hover_started = 0
		ui.audio_leave_started = 0
	}
}

imgui_build_settings :: proc(ui: ^ImGui_State, r: ^Renderer) {
	s := ui.dpi_scale
	imgui.SetNextWindowPos({title_bar_controls_end(s)-UI_ICON_BUTTON_SIZE*s, (TITLE_BAR_HEIGHT+4)*s}, .Always)
	imgui.SetNextWindowSizeConstraints({220*s, 0}, {500*s, 1000*s})
	if !imgui.BeginPopup("settings") do return
	defer imgui.EndPopup()
	ui.menu_open = true
	if imgui.MenuItem("Pin window position", nil, app.position_pin) do post_ui_action(.Pin)
	if imgui.MenuItem("Always on top", nil, app.always_on_top) do post_ui_action(.Topmost)
	imgui.Separator()
	can_configure := r.ready && !r.capture_suspended && r.reconnect_thread == nil && !renderer_edid_busy(r)
	can_screenshot := can_configure && sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0 &&
		sync.atomic_load_explicit(&r.video_sequence, .Acquire) != 0 && !screenshot_busy(&app.screenshot)
	if imgui.MenuItem("Save screenshot", "F8", false, can_screenshot) do post_ui_action(.Screenshot)
	if imgui.MenuItem("Reconnecting..." if r.reconnect_thread != nil else "Reconnect capture", nil, false, can_configure) do post_ui_action(.Reconnect)
	if imgui.BeginMenu("Capture health") {
		imgui_build_capture_health(r)
		imgui.EndMenu()
	}
	edid_open := imgui.BeginMenu("Input EDID mode")
	edid_item_tooltip(ui, "Change how your capture device and display share video settings. The connected 4K X is the source of truth.")
	if edid_open {
		if !ui.edid_menu_open do post_ui_action(.EDID_Refresh)
		ui.edid_menu_open = true
		imgui_build_edid_menu(ui, r)
		imgui.EndMenu()
	} else {
		ui.edid_menu_open = false
	}
	imgui.Separator()
	imgui.BeginDisabled(!can_configure)
	if imgui.BeginMenu("Resolution") {
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
		imgui.EndMenu()
	}
	if imgui.BeginMenu("Color format") {
		if imgui.MenuItem("Auto - match native mode", nil, r.format_auto) {
			post_ui_action(.ColorFormat, CAPTURE_FORMAT_COUNT)
		}
		for raw_format in 0..<CAPTURE_FORMAT_COUNT {
			format := Capture_Format(raw_format)
			if !capture_format_available(r, format) do continue
			if imgui.MenuItem(capture_format_menu_label(format), nil, !r.format_auto && r.capture_format == format) {
				post_ui_action(.ColorFormat, raw_format)
			}
		}
		imgui.EndMenu()
	}
	imgui.EndDisabled()
	if imgui.MenuItem("Show frame rate", "P", app.fps_visible) do app.fps_visible = !app.fps_visible
	if app.layout.save_failed {
		imgui.Separator()
		imgui.TextDisabledUnformatted("Window layout could not be saved")
	}
}

edid_item_tooltip :: proc(ui: ^ImGui_State, text: cstring) {
	if !imgui.IsItemHovered(imgui.HoveredFlags_ForTooltip | imgui.HoveredFlags_AllowWhenDisabled) do return
	imgui.SetNextWindowSize({320*ui.dpi_scale, 0}, .Always)
	if imgui.BeginTooltip() {
		imgui.TextWrappedUnformatted(text)
		imgui.EndTooltip()
	}
}

imgui_build_edid_menu :: proc(ui: ^ImGui_State, r: ^Renderer) {
	status := EDID_Availability(sync.atomic_load_explicit(&r.edid_status, .Acquire))
	known := sync.atomic_load_explicit(&r.edid_mode_known, .Acquire) != 0
	current := EDID_Mode(sync.atomic_load_explicit(&r.edid_mode, .Relaxed))
	can_select := status == .Ready && !renderer_edid_busy(r) &&
		sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0

	imgui.BeginDisabled(!can_select)
	if imgui.MenuItem("Merged (recommended)", nil, known && current == .Merged) do post_ui_action(.EDID_Mode, int(EDID_Mode.Merged))
	edid_item_tooltip(ui, "Automatically selects the best settings for both your capture device and display.")
	if imgui.MenuItem("Display", nil, known && current == .Display) do post_ui_action(.EDID_Mode, int(EDID_Mode.Display))
	edid_item_tooltip(ui, "Uses your TV or monitor's settings, ignoring your capture device.")
	if imgui.MenuItem("Internal", nil, known && current == .Internal) do post_ui_action(.EDID_Mode, int(EDID_Mode.Internal))
	edid_item_tooltip(ui, "Uses the EDID already stored on the card, ignoring your TV or monitor.")
	imgui.EndDisabled()

	imgui.Separator()
	refresh_enabled := r.capture_event != nil && !r.capture_suspended && r.reconnect_thread == nil &&
		sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0 && !renderer_edid_busy(r)
	if imgui.MenuItem("Refresh mode", nil, false, refresh_enabled) do post_ui_action(.EDID_Refresh)
	imgui.TextDisabledUnformatted(edid_status_text(r, status, known, current))
}

edid_status_text :: proc(r: ^Renderer, status: EDID_Availability, known: bool, mode: EDID_Mode) -> cstring {
	switch status {
	case .Reading: return "Reading mode..."
	case .Applying: return "Applying mode..."
	case .Reconnecting: return "Mode applied; reconnecting capture..."
	case .Unknown: return "Mode unknown - refresh required"
	case .Applied_Capture_Unavailable: return "Mode applied; capture unavailable"
	case .Unavailable:
		error := EDID_Protocol_Error(sync.atomic_load_explicit(&r.edid_error, .Relaxed))
		if error == .Unsupported do return "EDID extension unavailable for this device"
		if error == .Protocol_Version do return "Unsupported 4K X EDID protocol"
		return fmt.ctprintf("EDID verification failed: %s", edid_protocol_error_text(error))
	case .Error:
		error := EDID_Protocol_Error(sync.atomic_load_explicit(&r.edid_error, .Relaxed))
		if error == .Readback_Mismatch && known do return fmt.ctprintf("Card reports %s; requested mode did not match", edid_mode_name(mode))
		return fmt.ctprintf("Mode read failed: %s", edid_protocol_error_text(error))
	case .Ready:
		notice := EDID_Protocol_Error(sync.atomic_load_explicit(&r.edid_notice, .Relaxed))
		if notice == .Readback_Mismatch && known do return fmt.ctprintf("Card reports %s; requested mode did not match", edid_mode_name(mode))
		if known do return fmt.ctprintf("Current: %s", edid_mode_name(mode))
	}
	return "EDID control unavailable"
}

imgui_build_capture_health :: proc(r: ^Renderer) {
	h := &r.health
	totals := capture_health_totals(h)
	if r.reconnect_thread != nil {
		imgui.TextUnformatted("Reconnecting capture...")
	} else if r.capture_suspended {
		imgui.TextUnformatted("Capture paused")
	} else if !sync.atomic_load_explicit(&r.capture_running, .Acquire) {
		imgui.TextUnformatted("Capture unavailable")
	} else if sync.atomic_load_explicit(&r.capture_ready, .Acquire) == 0 {
		imgui.TextUnformatted("Connecting...")
	} else {
		imgui.TextUnformatted("Waiting for frames" if !h.has_samples || h.capture_stalled else "Frames arriving")
		capture_fps := f64(r.capture_fps_num)/f64(max(r.capture_fps_den, u32(1)))
		imgui.TextDisabledUnformatted(fmt.ctprintf("%dx%d @ %.1f FPS / %s", r.capture_width, r.capture_height, capture_fps, capture_format_selection_ui_name(r)))
	}
	if r.reconnect_error do imgui.TextUnformatted("Reconnect could not start; try again")
	imgui.Separator()
	imgui.TextUnformatted(fmt.ctprintf("Capture: %.1f FPS", h.capture_fps))
	imgui.TextUnformatted(fmt.ctprintf("Displayed: %.1f FPS", h.present_fps))
	if !h.has_samples {
		imgui.TextDisabledUnformatted("No frames received yet")
	} else {
		imgui.TextUnformatted(fmt.ctprintf("Last frame: %.0f ms ago", h.sample_age_ms))
	}
	imgui.Separator()
	imgui.TextDisabledUnformatted("Since this app was opened")
	imgui.TextUnformatted(fmt.ctprintf("Frames received: %d", totals.samples_received))
	imgui.TextUnformatted(fmt.ctprintf("Frames displayed: %d", totals.presented_frames))
	imgui.TextUnformatted(fmt.ctprintf("Dropped while busy: %d", totals.busy_drops))
	imgui.TextUnformatted(fmt.ctprintf("Frame conversion errors: %d", totals.upload_errors))
	imgui.TextUnformatted(fmt.ctprintf("Capture errors: %d", totals.source_errors))
	imgui.TextUnformatted(fmt.ctprintf("Recovery requests: %d", totals.recovery_requests))
	imgui.TextDisabledUnformatted("Counts viewer drops; upstream loss is not measured")
	imgui.Separator()
	imgui.TextUnformatted("Recent stalls")
	if h.stall_count == 0 do imgui.TextDisabledUnformatted("None recorded")
	for i in 0..<min(h.stall_count, 5) {
		index := (h.stall_next-1-i+len(h.stalls))%len(h.stalls)
		stall := h.stalls[index]
		kind := "Capture" if stall.kind == .Capture else "Display"
		imgui.TextUnformatted(fmt.ctprintf("%s: %.0f ms%s", kind, stall.duration_ms, " (ongoing)" if stall.ongoing else ""))
	}
}

imgui_build_capture_feedback :: proc(ui: ^ImGui_State, r: ^Renderer) {
	if !screenshot_busy(&app.screenshot) && time.diff(time.now(), app.screenshot_feedback_until) <= 0 do return
	s := ui.dpi_scale
	imgui.SetNextWindowPos({16*s, max(50*s, f32(r.height)-64*s)}, .Always)
	imgui.SetNextWindowSize({min(420*s, f32(r.width)-32*s), 0}, .Always)
	imgui.SetNextWindowSizeConstraints({0, 0}, {max(100*s, f32(r.width)-32*s), 160*s})
	imgui.SetNextWindowBgAlpha(0.94)
	imgui.Begin("##screenshot_feedback", nil, imgui.WindowFlags_NoDecoration | imgui.WindowFlags_NoInputs | {.AlwaysAutoResize, .NoSavedSettings, .NoFocusOnAppearing})
	imgui.TextWrappedUnformatted(fmt.ctprintf("%s", screenshot_status_text(&app.screenshot)))
	imgui.End()
}

imgui_draw_capture_status :: proc(ui: ^ImGui_State, r: ^Renderer, draw: ^imgui.DrawList, left, right: f32) {
	s := ui.dpi_scale
	if right-left < 18*s do return
	capture_ready := r.reconnect_thread == nil && sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0
	capture_running := sync.atomic_load_explicit(&r.capture_running, .Acquire)
	status_color := imgui.ColorConvertFloat4ToU32({0.38, 0.65, 0.48, 1})
	label: cstring = "Capture unavailable"
	if capture_ready {
		label = fmt.ctprintf("%dx%d  /  %.1f FPS", r.capture_width, r.capture_height, r.display_fps) if app.fps_visible else fmt.ctprintf("%dx%d", r.capture_width, r.capture_height)
	} else {
		status_color = imgui.ColorConvertFloat4ToU32({0.75, 0.58, 0.31, 1}) if capture_running else imgui.ColorConvertFloat4ToU32({0.63, 0.34, 0.34, 1})
		if capture_running do label = "Connecting..."
		if r.reconnect_thread != nil do label = "Reconnecting..."
	}
	text_left := left+13*s
	text_size := imgui.CalcTextSize(label)
	if text_size.x > right-text_left {
		label = fmt.ctprintf("%dx%d", r.capture_width, r.capture_height) if capture_ready else "Connecting" if capture_running else "Unavailable"
		text_size = imgui.CalcTextSize(label)
	}
	// Status shares the drag region, but never the window command buttons.
	imgui.DrawList_PushClipRect(draw, {left, 0}, {right, TITLE_BAR_HEIGHT*s}, true)
	imgui.DrawList_AddCircleFilled(draw, {left+3*s, TITLE_BAR_HEIGHT*s*0.5}, 2.5*s, status_color, 12)
	if text_size.x <= right-text_left {
		imgui.DrawList_AddText(draw, {text_left, (TITLE_BAR_HEIGHT*s-text_size.y)*0.5}, imgui.ColorConvertFloat4ToU32({0.52, 0.54, 0.56, 1}), label)
	}
	imgui.DrawList_PopClipRect(draw)
}

audio_volume_flyout :: proc(ui: ^ImGui_State, button_min, button_max: imgui.Vec2, button_hovered: bool) {
	s := ui.dpi_scale
	ui.menu_open = true
	height := f32(76)*s
	if audio_settings_save_failed(&app.audio) do height = 112*s
	imgui.PushStyleVar(.WindowRounding, 0)
	imgui.PushStyleVar(.WindowBorderSize, 1*s)
	imgui.PushStyleVar(.FrameRounding, 0)
	imgui.PushStyleVar(.GrabRounding, 0)
	imgui.PushStyleColorImVec4(.WindowBg, {0.018, 0.018, 0.018, 1})
	imgui.PushStyleColorImVec4(.Border, {0.28, 0.29, 0.31, 1})
	imgui.PushStyleColorImVec4(.Text, {0.82, 0.84, 0.87, 1})
	imgui.PushStyleColorImVec4(.FrameBg, {0.07, 0.07, 0.07, 1})
	imgui.PushStyleColorImVec4(.FrameBgHovered, {0.13, 0.13, 0.13, 1})
	imgui.PushStyleColorImVec4(.FrameBgActive, {0.20, 0.20, 0.20, 1})
	imgui.PushStyleColorImVec4(.SliderGrab, {0.58, 0.60, 0.63, 1})
	imgui.PushStyleColorImVec4(.SliderGrabActive, {0.82, 0.84, 0.87, 1})
	imgui.SetNextWindowPos({button_min.x, button_max.y+4*s}, .Always)
	imgui.SetNextWindowSize({AUDIO_VOLUME_FLYOUT_WIDTH*s, height}, .Always)
	imgui.Begin("##audio_volume_flyout", nil, AUDIO_VOLUME_WINDOW_FLAGS)
	imgui.TextUnformatted("Volume")
	imgui.SetNextItemWidth(-1)
	volume := i32(audio_get_volume_percent(&app.audio))
	if imgui.SliderInt("##audio_volume", &volume, 0, 100, "%d%%", imgui.SliderFlags_AlwaysClamp) {
		audio_set_volume_percent(&app.audio, u32(volume))
	}
	slider_active := imgui.IsItemActive()
	if imgui.IsItemDeactivatedAfterEdit() do audio_save_settings(&app.audio)
	if audio_settings_save_failed(&app.audio) {
		imgui.TextWrappedUnformatted("Volume could not be saved beside Elga")
	}
	flyout_hovered := imgui.IsWindowHovered()
	imgui.End()
	imgui.PopStyleColor(8)
	imgui.PopStyleVar(4)

	now := imgui.GetTime()
	if button_hovered || flyout_hovered || slider_active {
		ui.audio_leave_started = 0
		return
	}
	if ui.audio_leave_started == 0 do ui.audio_leave_started = now
	if now-ui.audio_leave_started >= AUDIO_VOLUME_LEAVE_DELAY {
		ui.audio_volume_open = false
		ui.audio_hover_started = 0
		ui.audio_leave_started = 0
	}
}

wake_set_tooltip :: proc(w: ^Wake_Control, status: Wake_Status, online: bool) {
	if !online {
		if !wake_health_was_checked(w) {
			imgui.SetTooltipUnformatted("Checking Switch 2 wake beacon...")
			return
		}
		switch wake_get_health_error(w) {
		case .Resolve:        imgui.SetTooltipUnformatted("Wake unavailable: could not resolve switch2-waker.local")
		case .Connect:        imgui.SetTooltipUnformatted("Wake unavailable: beacon is offline")
		case .Timeout:        imgui.SetTooltipUnformatted("Wake unavailable: beacon timed out")
		case .Http:           imgui.SetTooltip("Wake unavailable: beacon returned HTTP %u", wake_get_health_http_status(w))
		case .Curl_Global_Init: imgui.SetTooltipUnformatted("Wake unavailable: libcurl initialization failed")
		case .Health_Monitor_Init: imgui.SetTooltipUnformatted("Wake unavailable: health monitor could not start")
		case .Curl_Easy_Init, .Curl_Setup, .Thread_Create, .Cancelled, .Transfer, .None:
			imgui.SetTooltipUnformatted("Wake unavailable: beacon health check failed")
		}
		return
	}

	switch status {
	case .Unavailable: imgui.SetTooltipUnformatted("Switch wake is unavailable")
	case .Idle:        imgui.SetTooltipUnformatted("Wake Nintendo Switch 2")
	case .Sending:     imgui.SetTooltipUnformatted("Sending Switch 2 wake request...")
	case .Success:     imgui.SetTooltipUnformatted("Switch 2 wake request sent")
	case .Failed:
		switch wake_get_error(w) {
		case .Thread_Create:  imgui.SetTooltipUnformatted("Switch wake failed: could not create worker thread")
		case .Curl_Easy_Init: imgui.SetTooltipUnformatted("Switch wake failed: could not create curl request")
		case .Curl_Setup:     imgui.SetTooltipUnformatted("Switch wake failed: could not configure curl")
		case .Resolve:        imgui.SetTooltipUnformatted("Switch wake failed: could not resolve switch2-waker.local")
		case .Connect:        imgui.SetTooltipUnformatted("Switch wake failed: beacon refused the connection")
		case .Timeout:        imgui.SetTooltipUnformatted("Switch wake failed: beacon timed out")
		case .Http:           imgui.SetTooltip("Switch wake failed: beacon returned HTTP %u", wake_get_http_status(w))
		case .Cancelled:      imgui.SetTooltipUnformatted("Switch wake request was cancelled")
		case .None, .Curl_Global_Init, .Health_Monitor_Init, .Transfer:
			imgui.SetTooltipUnformatted("Switch wake failed during transfer")
		}
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
	case .Settings:
		for i in 0..<3 {
			offset := f32(i-1)*7
			imgui.DrawList_AddCircleFilled(draw, {c.x+offset*s, c.y}, 1.7*s, color, 12)
		}
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
	if msg == win32.WM_SETFOCUS || msg == win32.WM_KILLFOCUS {
		// Hidden and minimized overlays do not run NewFrame. Keep only the
		// latest focus state instead of allocating an event for every alt-tab.
		ui.focus_dirty = true
		ui.focused = msg == win32.WM_SETFOCUS
		ui.focus_lost = ui.focus_lost || !ui.focused
		return
	}
	if msg == win32.WM_MOUSEMOVE {
		ui.mouse_pos = {f32(win32.GET_X_LPARAM(lparam)), f32(win32.GET_Y_LPARAM(lparam))}
		ui.mouse_dirty = true
		if !ui.mouse_tracking {
			tracking := win32.TRACKMOUSEEVENT {
				cbSize = size_of(win32.TRACKMOUSEEVENT),
				dwFlags = win32.TME_LEAVE,
				hwndTrack = hwnd,
			}
			ui.mouse_tracking = bool(win32.TrackMouseEvent(&tracking))
		}
	} else if msg == win32.WM_MOUSELEAVE {
		ui.mouse_pos = {-1, -1}
		ui.mouse_dirty = true
		ui.mouse_tracking = false
	}
	// Do not accumulate stale canvas clicks while ImGui is completely hidden.
	// Mouse movement is retained separately for the next visible frame.
	if !app.controls_visible && !ui.menu_open do return
	io := imgui.GetIO()
	switch msg {
	case win32.WM_LBUTTONDOWN, win32.WM_LBUTTONDBLCLK:
		imgui_ui_queue_mouse_button(ui, io, 0, true, lparam)
		win32.SetCapture(hwnd)
	case win32.WM_LBUTTONUP:
		imgui_ui_queue_mouse_button(ui, io, 0, false, lparam)
		win32.ReleaseCapture()
	case win32.WM_RBUTTONDOWN, win32.WM_RBUTTONDBLCLK:
		imgui_ui_queue_mouse_button(ui, io, 1, true, lparam)
		win32.SetCapture(hwnd)
	case win32.WM_RBUTTONUP:
		imgui_ui_queue_mouse_button(ui, io, 1, false, lparam)
		win32.ReleaseCapture()
	case win32.WM_MBUTTONDOWN, win32.WM_MBUTTONDBLCLK:
		imgui_ui_queue_mouse_button(ui, io, 2, true, lparam)
		win32.SetCapture(hwnd)
	case win32.WM_MBUTTONUP:
		imgui_ui_queue_mouse_button(ui, io, 2, false, lparam)
		win32.ReleaseCapture()
	case win32.WM_MOUSEWHEEL:
		imgui_ui_flush_mouse_position(ui, io)
		imgui.IO_AddMouseWheelEvent(io, 0, f32(win32.GET_WHEEL_DELTA_WPARAM(wparam))/f32(win32.WHEEL_DELTA))
	case win32.WM_MOUSEHWHEEL:
		imgui_ui_flush_mouse_position(ui, io)
		imgui.IO_AddMouseWheelEvent(io, f32(win32.GET_WHEEL_DELTA_WPARAM(wparam))/f32(win32.WHEEL_DELTA), 0)
	}
}

imgui_ui_flush_focus :: proc(ui: ^ImGui_State, io: ^imgui.IO) {
	if !ui.focus_dirty do return
	if ui.focus_lost {
		// A loss followed by a gain before the next frame must still release
		// held input, including a mouse release delivered while UI was hidden.
		imgui.IO_ClearEventsQueue(io)
		imgui.IO_ClearInputKeys(io)
		imgui.IO_ClearInputMouse(io)
		ui.mouse_dirty = true
	}
	imgui.IO_AddFocusEvent(io, ui.focused)
	ui.focus_dirty, ui.focus_lost = false, false
}

imgui_ui_flush_mouse_position :: proc(ui: ^ImGui_State, io: ^imgui.IO) {
	imgui_ui_flush_focus(ui, io)
	if !ui.mouse_dirty do return
	imgui.IO_AddMousePosEvent(io, ui.mouse_pos.x, ui.mouse_pos.y)
	ui.mouse_dirty = false
}

imgui_ui_queue_mouse_button :: proc(ui: ^ImGui_State, io: ^imgui.IO, button: i32, down: bool, lparam: win32.LPARAM) {
	// Preserve the position at each button transition before ImGui trickles its
	// input queue across frames. Waiting until NewFrame applies fast clicks to
	// the previous position, and a later move can overwrite the click location.
	ui.mouse_pos = {f32(win32.GET_X_LPARAM(lparam)), f32(win32.GET_Y_LPARAM(lparam))}
	ui.mouse_dirty = true
	imgui_ui_flush_mouse_position(ui, io)
	imgui.IO_AddMouseButtonEvent(io, button, down)
}
