package main

import "core:fmt"
import "core:sync"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

// A driver update, crash or GPU reset removes both D3D11 devices. Every GPU
// object is rebuilt on the window thread: capture stops on the reconnect
// worker, then the devices, swap chain, video pipeline, ImGui backend and
// enhancement session are recreated and capture restarts with the same choice.
DEVICE_RECOVERY_MAX_DELAY :: 5*time.Second
// Windows can briefly offer only its software adapter while a driver restarts.
// Wait this many attempts for hardware before accepting it.
DEVICE_RECOVERY_BASIC_RENDER_ATTEMPTS :: 10
BASIC_RENDER_VENDOR_ID :: 0x1414
BASIC_RENDER_DEVICE_ID :: 0x8c
// Reported when GPU resources could not be restored on a device that was not removed.
RENDERER_RESOURCES_FAILED :: win32.HRESULT(-2147467259) // E_FAIL

DEVICE_LOST_WINDOW_TITLE := win32.L("Elgato 4K X - restoring graphics device")
DEVICE_LOST_MESSAGE := win32.L("Graphics device lost. Restoring video...")

renderer_device_lost_error :: proc(hr: win32.HRESULT) -> bool {
	switch hr {
	case dxgi.ERROR_DEVICE_REMOVED, dxgi.ERROR_DEVICE_RESET, dxgi.ERROR_DEVICE_HUNG, dxgi.ERROR_DRIVER_INTERNAL_ERROR:
		return true
	}
	return false
}

// S_OK while both devices are usable. Cheap enough to poll from the UI tick,
// which also catches a lost capture device that Present never reports.
renderer_device_removed_reason :: proc(r: ^Renderer) -> win32.HRESULT {
	for device in ([2]^d3d11.IDevice{r.device_11, r.capture_device_11}) {
		if device == nil do continue
		if reason := device.GetDeviceRemovedReason(device); failed(reason) do return reason
	}
	return win32.HRESULT(win32.S_OK)
}

// Stops all GPU work at once; Present may call this mid-draw. The rebuild
// itself waits for the UI tick, after the draw has unwound.
renderer_mark_device_lost :: proc(r: ^Renderer, reason: win32.HRESULT) {
	if r.device_lost do return
	removed := renderer_device_removed_reason(r)
	r.device_lost = true
	r.device_lost_reason = removed if failed(removed) else reason
	r.ready = false
	r.device_retry_count = 0
	r.device_retry_at = {}
	renderer_cancel_redraw_retry(r)
	// Audio must not stay delayed for enhanced video that is no longer shown.
	video_enhancements_reset_audio(&r.enhancements)
	fmt.eprintf("Graphics device lost (0x%08x); rebuilding GPU resources\n", u32(r.device_lost_reason))
}

// UI tick. Detects loss and stops capture without blocking the window thread.
// Returns true once a rebuild attempt may start: no draw, worker or capture
// thread is running, the window is not minimized and any retry delay is over.
renderer_device_recovery_due :: proc(r: ^Renderer, now: time.Time) -> bool {
	if r.drawing do return false
	if !r.device_lost {
		if r.device_11 == nil do return false
		reason := renderer_device_removed_reason(r)
		if !failed(reason) {
			if r.ready do return false
			reason = RENDERER_RESOURCES_FAILED
		}
		renderer_mark_device_lost(r, reason)
	}
	// Includes a user reconnect that was already releasing the source.
	if r.reconnect_thread != nil do return false
	if r.capture_thread != nil {
		// Source shutdown can block inside the driver; it runs on the worker.
		if renderer_start_capture_shutdown(r) do return false
		capture_stop(r)
	}
	// Restoring sends WM_SIZE; build at the restored size instead of 1x1.
	if r.hwnd != nil && win32.IsIconic(r.hwnd) do return false
	return r.device_retry_at == {} || time.diff(r.device_retry_at, now) >= 0
}

renderer_schedule_device_retry :: proc(r: ^Renderer, now: time.Time) {
	r.device_retry_count += 1
	delay := min(time.Duration(r.device_retry_count)*time.Second, DEVICE_RECOVERY_MAX_DELAY)
	r.device_retry_at = time.time_add(now, delay)
	fmt.eprintf("Graphics device recovery attempt %d failed; retrying in %.0f s\n", r.device_retry_count, time.duration_seconds(delay))
}

// Runs on new devices from renderer_create_device_objects. Restarts capture with
// the user's format and resolution; Auto is resolved again once the new session
// enumerates its modes. A capture failure leaves the GPU usable and is reported
// like any other capture failure.
renderer_restart_after_device_loss :: proc(r: ^Renderer) -> bool {
	width, height := r.requested_width, r.requested_height
	if width == 0 || height == 0 do width, height = capture_default_size(r, r.capture_format, true)
	if !video_resources_create(r, r.capture_format, width, height) do return false
	video_pipeline_bind(r)
	r.mode = {}
	r.last_presented_seq = 0
	sync.atomic_store_explicit(&r.video_sequence, 0, .Release)
	sync.atomic_store_explicit(&r.video_vertical_flip, 0, .Release)
	r.capture_suspended, r.suspend_requested = false, false
	r.suspended_resource_width, r.suspended_resource_height = 0, 0
	r.pending_width, r.pending_height = 0, 0
	r.startup_auto_resolved = false
	r.reconnect_error = false
	r.display_fps = 0
	r.last_video_present = {}
	r.fps_window_frames = 0
	r.fps_window_start = time.now()
	r.device_recoveries += 1
	fmt.eprintf("Graphics device recovered after %d attempt(s)\n", r.device_retry_count+1)
	r.device_lost = false
	r.device_retry_count = 0
	r.device_retry_at = {}
	r.ready = true
	if !capture_start(r) do fmt.eprintln("Could not restart capture after graphics device recovery")
	renderer_request_redraw(r)
	return true
}

// UI tick. Rebuilds the renderer and the ImGui backend after device loss.
// Returns true when anything the window shows has changed.
app_update_device_recovery :: proc() -> bool {
	r := &app.renderer
	now := time.now()
	due := renderer_device_recovery_due(r, now)
	changed := app_show_device_lost(r.device_lost)
	if !due do return changed
	imgui_ui_release_device(&app.ui)
	renderer_release_device_objects(r)
	client: win32.RECT
	win32.GetClientRect(app.hwnd, &client)
	allow_basic_render := r.device_retry_count >= DEVICE_RECOVERY_BASIC_RENDER_ATTEMPTS
	if renderer_create_device_objects(r, u32(max(client.right, 0)), u32(max(client.bottom, 0)), allow_basic_render) &&
	   imgui_ui_attach_device(&app.ui, r) && renderer_restart_after_device_loss(r) {
		app_show_device_lost(false)
		return true
	}
	imgui_ui_release_device(&app.ui)
	renderer_release_device_objects(r)
	renderer_schedule_device_retry(r, now)
	// No swap chain owns the window now, so GDI can show the status message.
	renderer_request_redraw(r)
	return true
}

// The custom title bar needs the GPU, so the taskbar title carries the status.
app_show_device_lost :: proc(lost: bool) -> bool {
	if app.device_lost_shown == lost do return false
	app.device_lost_shown = lost
	win32.SetWindowTextW(app.hwnd, cstring16(DEVICE_LOST_WINDOW_TITLE if lost else WINDOW_TITLE))
	return true
}

// WM_PAINT while no swap chain exists. Without one the window shows GDI output.
window_paint_device_lost :: proc(hwnd: win32.HWND, hdc: win32.HDC) {
	if hdc == nil do return
	client: win32.RECT
	win32.GetClientRect(hwnd, &client)
	win32.FillRect(hdc, &client, win32.HBRUSH(win32.GetStockObject(win32.BLACK_BRUSH)))
	previous_font := win32.SelectObject(hdc, win32.GetStockObject(win32.DEFAULT_GUI_FONT))
	win32.SetBkMode(hdc, .TRANSPARENT)
	win32.SetTextColor(hdc, win32.RGB(210, 214, 222))
	format := win32.DrawTextFormat(u32(win32.DrawTextFormat.DT_CENTER) | u32(win32.DrawTextFormat.DT_VCENTER) | u32(win32.DrawTextFormat.DT_SINGLELINE))
	win32.DrawTextW(hdc, cstring16(DEVICE_LOST_MESSAGE), -1, &client, format)
	win32.SelectObject(hdc, previous_font)
}
