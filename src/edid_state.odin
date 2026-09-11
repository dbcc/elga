package main

import "core:fmt"
import "core:sync"
import win32 "core:sys/windows"

renderer_edid_busy :: proc(r: ^Renderer) -> bool {
	if r == nil do return false
	return sync.atomic_load_explicit(&r.edid_operation_active, .Acquire) != 0 ||
		sync.atomic_load_explicit(&r.edid_request_kind, .Acquire) != u32(EDID_Request_Kind.None) ||
		sync.atomic_load_explicit(&r.edid_result_pending, .Acquire) != 0 ||
		sync.atomic_load_explicit(&r.capture_refresh, .Acquire) != 0 ||
		r.reconnect_thread != nil
}

renderer_request_edid_refresh :: proc(r: ^Renderer) -> bool {
	if r == nil || !r.ready || r.capture_suspended || r.capture_event == nil ||
	   sync.atomic_load_explicit(&r.capture_ready, .Acquire) == 0 || renderer_edid_busy(r) {
		return false
	}
	request_id := sync.atomic_add_explicit(&r.edid_request_id, 1, .Acq_Rel)+1
	sync.atomic_store_explicit(&r.edid_request_generation, sync.atomic_load_explicit(&r.capture_generation, .Acquire), .Relaxed)
	sync.atomic_store_explicit(&r.edid_error, u32(EDID_Protocol_Error.None), .Relaxed)
	sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Reading), .Release)
	sync.atomic_store_explicit(&r.edid_request_kind, u32(EDID_Request_Kind.Refresh), .Release)
	win32.SetEvent(r.capture_event)
	fmt.eprintf("EDID refresh requested: request=%d\n", request_id)
	return true
}

renderer_request_edid_mode :: proc(r: ^Renderer, mode: EDID_Mode) -> bool {
	if r == nil || !r.ready || r.capture_suspended || r.capture_event == nil || renderer_edid_busy(r) do return false
	if EDID_Availability(sync.atomic_load_explicit(&r.edid_status, .Acquire)) != .Ready do return false
	if sync.atomic_load_explicit(&r.edid_mode_known, .Acquire) != 0 &&
	   EDID_Mode(sync.atomic_load_explicit(&r.edid_mode, .Relaxed)) == mode {
		return true
	}
	request_id := sync.atomic_add_explicit(&r.edid_request_id, 1, .Acq_Rel)+1
	sync.atomic_store_explicit(&r.edid_request_generation, sync.atomic_load_explicit(&r.capture_generation, .Acquire), .Relaxed)
	sync.atomic_store_explicit(&r.edid_requested_mode, u32(mode), .Relaxed)
	sync.atomic_store_explicit(&r.edid_error, u32(EDID_Protocol_Error.None), .Relaxed)
	sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Applying), .Release)
	sync.atomic_store_explicit(&r.edid_request_kind, u32(EDID_Request_Kind.Set), .Release)
	win32.SetEvent(r.capture_event)
	fmt.eprintf("EDID mode change requested: request=%d mode=%s\n", request_id, edid_mode_name(mode))
	return true
}

renderer_publish_edid_result :: proc(r: ^Renderer, result: EDID_Result) {
	if r == nil || result.generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) do return
	sync.atomic_store_explicit(&r.edid_mode, u32(result.mode), .Relaxed)
	sync.atomic_store_explicit(&r.edid_mode_known, 1 if result.mode_known else 0, .Relaxed)
	sync.atomic_store_explicit(&r.edid_error, u32(result.error), .Relaxed)
	sync.atomic_store_explicit(&r.edid_result_id, result.request_id, .Relaxed)
	sync.atomic_store_explicit(&r.edid_result_generation, result.generation, .Relaxed)
	sync.atomic_store_explicit(&r.edid_result_disposition, u32(result.disposition), .Relaxed)
	if result.disposition == .May_Have_Applied {
		sync.atomic_store_explicit(&r.edid_verification_required, 1, .Relaxed)
		sync.atomic_store_explicit(&r.edid_notice, u32(EDID_Protocol_Error.Readback_Failed), .Relaxed)
	} else if result.disposition == .Applied_Mismatch {
		sync.atomic_store_explicit(&r.edid_verification_required, 0, .Relaxed)
		sync.atomic_store_explicit(&r.edid_notice, u32(EDID_Protocol_Error.Readback_Mismatch), .Relaxed)
	} else if result.error == .None {
		sync.atomic_store_explicit(&r.edid_verification_required, 0, .Relaxed)
		sync.atomic_store_explicit(&r.edid_notice, u32(EDID_Protocol_Error.None), .Relaxed)
	}
	status := EDID_Availability.Ready
	if !result.mode_known do status = .Unknown
	if result.disposition == .Not_Applied && result.error != .None do status = .Error
	if edid_requires_reconnect(result.disposition) do status = .Reconnecting
	sync.atomic_store_explicit(&r.edid_status, u32(status), .Relaxed)
	sync.atomic_store_explicit(&r.edid_result_pending, 1, .Release)
	win32.PostMessageW(r.hwnd, EDID_RESULT_MESSAGE, win32.WPARAM(result.generation), win32.LPARAM(result.request_id))
}

renderer_handle_edid_result :: proc(r: ^Renderer, generation, request_id: u32) {
	if r == nil || sync.atomic_load_explicit(&r.edid_result_pending, .Acquire) == 0 do return
	if generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) ||
	   generation != sync.atomic_load_explicit(&r.edid_result_generation, .Relaxed) ||
	   request_id != sync.atomic_load_explicit(&r.edid_result_id, .Relaxed) {
		return
	}
	// An old window message must not consume a newer session's pending result.
	sync.atomic_store_explicit(&r.edid_result_pending, 0, .Release)
	error := EDID_Protocol_Error(sync.atomic_load_explicit(&r.edid_error, .Relaxed))
	disposition := EDID_Set_Disposition(sync.atomic_load_explicit(&r.edid_result_disposition, .Relaxed))
	if error != .None do fmt.eprintf("EDID operation result: request=%d error=%v disposition=%v\n", request_id, error, disposition)
	if edid_requires_reconnect(disposition) {
		sync.atomic_store_explicit(&r.edid_restore_pending, 1, .Release)
		sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Reconnecting), .Release)
		if !renderer_request_reconnect(r, false) {
			sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Applied_Capture_Unavailable), .Release)
		}
	} else if r.suspend_requested {
		// Use the same asynchronous source-shutdown worker as reconnect. The UI
		// thread will finish minimizing when renderer_update_reconnect observes it.
		renderer_request_reconnect(r, false)
	}
	renderer_request_redraw(r)
}

renderer_edid_capture_ready :: proc(r: ^Renderer, generation: u32) {
	if r == nil || generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) do return
	sync.atomic_store_explicit(&r.edid_restore_pending, 0, .Release)
}

renderer_edid_capture_failed :: proc(r: ^Renderer, generation: u32) {
	if r == nil || generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) do return
	if sync.atomic_load_explicit(&r.edid_restore_pending, .Acquire) != 0 {
		sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Applied_Capture_Unavailable), .Release)
	}
}
