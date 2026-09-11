package main

import "core:sync"
import "core:thread"
import "core:time"

// Releasing a USB capture source can take time inside the driver. Only its
// shutdown runs on this worker; GPU resource changes stay on the window thread.
renderer_request_reconnect :: proc(r: ^Renderer, count_recovery := true) -> bool {
	if r == nil || !r.ready || r.capture_suspended || r.drawing || r.reconnect_thread != nil do return false
	if sync.atomic_load_explicit(&r.edid_operation_active, .Acquire) != 0 ||
	   sync.atomic_load_explicit(&r.edid_request_kind, .Acquire) != u32(EDID_Request_Kind.None) {
		return false
	}
	r.reconnect_error = false
	sync.atomic_store_explicit(&r.reconnect_done, 0, .Release)
	r.reconnect_thread = thread.create(renderer_reconnect_thread_proc, .Normal, "capture-reconnect")
	if r.reconnect_thread == nil {
		r.reconnect_error = true
		return false
	}
	// Invalidate callbacks and pending screenshots belonging to the old session.
	sync.atomic_add_explicit(&r.capture_generation, 1, .Acq_Rel)
	if count_recovery do capture_health_note_recovery(&r.health)
	capture_health_reset_timing(r)
	r.reconnect_thread.data = r
	thread.start(r.reconnect_thread)
	renderer_request_redraw(r)
	return true
}

renderer_reconnect_thread_proc :: proc(t: ^thread.Thread) {
	r := cast(^Renderer)t.data
	capture_stop(r)
	sync.atomic_store_explicit(&r.reconnect_done, 1, .Release)
}

// Poll from the existing UI tick, so a failed PostMessage cannot strand a job.
renderer_update_reconnect :: proc(r: ^Renderer) -> bool {
	if r.reconnect_thread == nil || r.drawing || sync.atomic_load_explicit(&r.reconnect_done, .Acquire) == 0 do return false
	thread.join(r.reconnect_thread)
	thread.destroy(r.reconnect_thread)
	r.reconnect_thread = nil
	sync.atomic_store_explicit(&r.reconnect_done, 0, .Release)
	if r.suspend_requested || r.capture_suspended {
		renderer_suspend_capture(r)
		return true
	}
	// Keep the requested resolution/format. Auto is resolved again against the
	// fresh device enumeration, including when the previous device was missing.
	r.startup_auto_resolved = false
	r.display_fps = 0
	r.last_video_present = {}
	r.fps_window_frames = 0
	r.fps_window_start = time.now()
	renderer_apply_capture_configuration(r, r.capture_format, r.requested_width, r.requested_height, r.format_auto)
	r.reconnect_error = !r.ready || !sync.atomic_load_explicit(&r.capture_running, .Acquire)
	if r.reconnect_error && sync.atomic_load_explicit(&r.edid_restore_pending, .Acquire) != 0 {
		sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Applied_Capture_Unavailable), .Release)
	}
	renderer_request_redraw(r)
	return true
}
