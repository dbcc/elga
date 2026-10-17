package main

import "core:fmt"
import "core:sync"
import win32 "core:sys/windows"

// EDID state shared by the window and capture threads. Every field is accessed
// atomically; the store/load orderings below carry the hand-off protocol.
EDID_Channel :: struct {
	// Published for the UI: EDID_Availability, EDID_Protocol_Error, EDID_Mode.
	status:     u32,
	error:      u32,
	mode:       u32,
	mode_known: u32,
	// A lasting warning, such as a readback mismatch, shown while Ready.
	notice:     u32,
	// Single-entry request mailbox drained by the capture thread.
	request_kind:       u32,
	request_id:         u32,
	request_generation: u32,
	requested_mode:     u32,
	operation_active:   u32,
	// A finished request awaiting the window thread.
	result_pending:     u32,
	result_id:          u32,
	result_generation:  u32,
	result_disposition: u32,
	// Follow-up after a write that may have changed the card.
	restore_pending:       u32,
	verification_required: u32,
	// HDMI color range, published like the mode: EDID_Availability,
	// EDID_Protocol_Error, Color_Range. A failed write never reconnects.
	color_range_status:    u32,
	color_range_error:     u32,
	color_range:           u32,
	color_range_known:     u32,
	requested_color_range: u32,
}

// An EDID transfer is queued for, or running on, the capture thread.
renderer_edid_in_flight :: proc(r: ^Renderer) -> bool {
	return sync.atomic_load_explicit(&r.edid.operation_active, .Acquire) != 0 ||
		sync.atomic_load_explicit(&r.edid.request_kind, .Acquire) != u32(EDID_Request_Kind.None)
}

// Capture may not be reconfigured until EDID work and its follow-up settle.
renderer_edid_busy :: proc(r: ^Renderer) -> bool {
	if r == nil do return false
	return renderer_edid_in_flight(r) ||
		sync.atomic_load_explicit(&r.edid.result_pending, .Acquire) != 0 ||
		sync.atomic_load_explicit(&r.capture_refresh, .Acquire) != 0 ||
		r.reconnect_thread != nil
}

// Publishes the EDID state shown by the UI. A nil mode marks it unknown.
renderer_set_edid_state :: proc(r: ^Renderer, status: EDID_Availability, error: EDID_Protocol_Error, mode: Maybe(EDID_Mode) = nil) {
	current, known := mode.?
	if known do sync.atomic_store_explicit(&r.edid.mode, u32(current), .Relaxed)
	sync.atomic_store_explicit(&r.edid.mode_known, 1 if known else 0, .Relaxed)
	sync.atomic_store_explicit(&r.edid.error, u32(error), .Relaxed)
	sync.atomic_store_explicit(&r.edid.status, u32(status), .Release)
}

// Publishes the color range shown by the UI. A nil range marks it unknown.
renderer_set_color_range_state :: proc(r: ^Renderer, status: EDID_Availability, error: EDID_Protocol_Error, range: Maybe(Color_Range) = nil) {
	current, known := range.?
	if known do sync.atomic_store_explicit(&r.edid.color_range, u32(current), .Relaxed)
	sync.atomic_store_explicit(&r.edid.color_range_known, 1 if known else 0, .Relaxed)
	sync.atomic_store_explicit(&r.edid.color_range_error, u32(error), .Relaxed)
	sync.atomic_store_explicit(&r.edid.color_range_status, u32(status), .Release)
}

// Capture thread: reports what EDID control a newly opened session offers.
renderer_publish_edid_open :: proc(
	r: ^Renderer,
	generation: u32,
	available: bool,
	mode: EDID_Mode,
	error: EDID_Protocol_Error,
	node_id: u32,
	color_range: Color_Range,
	color_range_error: EDID_Protocol_Error,
) {
	if !available {
		renderer_set_edid_state(r, .Unavailable, .Unsupported)
		renderer_set_color_range_state(r, .Unavailable, .Unsupported)
		fmt.eprintln("EDID extension unavailable on the selected capture source")
		return
	}
	if generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) do return
	if error != .None {
		renderer_set_color_range_state(r, .Unavailable, error)
	} else if color_range_error == .None {
		renderer_set_color_range_state(r, .Ready, .None, color_range)
		fmt.eprintf("Color range read: %s\n", COLOR_RANGE_NAME[color_range])
	} else {
		renderer_set_color_range_state(r, .Error, color_range_error)
		fmt.eprintf("Color range read failed: %v\n", color_range_error)
	}
	if sync.atomic_load_explicit(&r.edid.verification_required, .Acquire) != 0 {
		renderer_set_edid_state(r, .Unknown, .Readback_Failed)
		fmt.eprintln("EDID write remains unverified; explicit refresh required")
	} else if error == .None {
		renderer_set_edid_state(r, .Ready, .None, mode)
		fmt.eprintf("EDID protocol verified: node=%d mode=%s\n", node_id, EDID_MODE_NAME[mode])
	} else {
		renderer_set_edid_state(r, .Unavailable, error)
		fmt.eprintf("EDID protocol validation failed: %v\n", error)
	}
}

renderer_request_edid_refresh :: proc(r: ^Renderer) -> bool {
	if r == nil || !r.ready || r.capture_suspended || r.capture_event == nil ||
	   sync.atomic_load_explicit(&r.capture_ready, .Acquire) == 0 || renderer_edid_busy(r) {
		return false
	}
	request_id := renderer_queue_edid_request(r, .Refresh)
	fmt.eprintf("EDID refresh requested: request=%d\n", request_id)
	return true
}

renderer_request_edid_mode :: proc(r: ^Renderer, mode: EDID_Mode) -> bool {
	if r == nil || !r.ready || r.capture_suspended || r.capture_event == nil || renderer_edid_busy(r) do return false
	if EDID_Availability(sync.atomic_load_explicit(&r.edid.status, .Acquire)) != .Ready do return false
	if sync.atomic_load_explicit(&r.edid.mode_known, .Acquire) != 0 &&
	   EDID_Mode(sync.atomic_load_explicit(&r.edid.mode, .Relaxed)) == mode {
		return true
	}
	sync.atomic_store_explicit(&r.edid.requested_mode, u32(mode), .Relaxed)
	request_id := renderer_queue_edid_request(r, .Set)
	fmt.eprintf("EDID mode change requested: request=%d mode=%s\n", request_id, EDID_MODE_NAME[mode])
	return true
}

renderer_request_color_range :: proc(r: ^Renderer, range: Color_Range) -> bool {
	if r == nil || !r.ready || r.capture_suspended || r.capture_event == nil || renderer_edid_busy(r) do return false
	if EDID_Availability(sync.atomic_load_explicit(&r.edid.color_range_status, .Acquire)) != .Ready do return false
	if sync.atomic_load_explicit(&r.edid.color_range_known, .Acquire) != 0 &&
	   Color_Range(sync.atomic_load_explicit(&r.edid.color_range, .Relaxed)) == range {
		return true
	}
	sync.atomic_store_explicit(&r.edid.requested_color_range, u32(range), .Relaxed)
	request_id := renderer_queue_edid_request(r, .Set_Color_Range)
	fmt.eprintf("Color range change requested: request=%d range=%s\n", request_id, COLOR_RANGE_NAME[range])
	return true
}

// Fills the single-entry mailbox the capture thread drains between samples.
// Only the settings the request touches show progress.
renderer_queue_edid_request :: proc(r: ^Renderer, kind: EDID_Request_Kind) -> u32 {
	request_id := sync.atomic_add_explicit(&r.edid.request_id, 1, .Acq_Rel)+1
	sync.atomic_store_explicit(&r.edid.request_generation, sync.atomic_load_explicit(&r.capture_generation, .Acquire), .Relaxed)
	if kind != .Set_Color_Range {
		sync.atomic_store_explicit(&r.edid.error, u32(EDID_Protocol_Error.None), .Relaxed)
		sync.atomic_store_explicit(&r.edid.status, u32(EDID_Availability.Applying if kind == .Set else EDID_Availability.Reading), .Release)
	}
	if kind != .Set {
		sync.atomic_store_explicit(&r.edid.color_range_error, u32(EDID_Protocol_Error.None), .Relaxed)
		sync.atomic_store_explicit(&r.edid.color_range_status, u32(EDID_Availability.Applying if kind == .Set_Color_Range else EDID_Availability.Reading), .Release)
	}
	sync.atomic_store_explicit(&r.edid.request_kind, u32(kind), .Release)
	win32.SetEvent(r.capture_event)
	return request_id
}

// Capture thread: publishes a finished request for the window thread.
renderer_publish_edid_result :: proc(r: ^Renderer, result: EDID_Result) {
	if r == nil || result.generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) do return
	sync.atomic_store_explicit(&r.edid.result_id, result.request_id, .Relaxed)
	sync.atomic_store_explicit(&r.edid.result_generation, result.generation, .Relaxed)
	sync.atomic_store_explicit(&r.edid.result_disposition, u32(result.disposition), .Relaxed)
	if result.kind != .Set do renderer_publish_color_range_result(r, result)
	if result.kind != .Set_Color_Range do renderer_publish_edid_mode_result(r, result)
	sync.atomic_store_explicit(&r.edid.result_pending, 1, .Release)
	win32.PostMessageW(r.hwnd, EDID_RESULT_MESSAGE, win32.WPARAM(result.generation), win32.LPARAM(result.request_id))
}

renderer_publish_edid_mode_result :: proc(r: ^Renderer, result: EDID_Result) {
	#partial switch result.disposition {
	case .May_Have_Applied:
		sync.atomic_store_explicit(&r.edid.verification_required, 1, .Relaxed)
		sync.atomic_store_explicit(&r.edid.notice, u32(EDID_Protocol_Error.Readback_Failed), .Relaxed)
	case .Applied_Mismatch:
		sync.atomic_store_explicit(&r.edid.verification_required, 0, .Relaxed)
		sync.atomic_store_explicit(&r.edid.notice, u32(EDID_Protocol_Error.Readback_Mismatch), .Relaxed)
	case:
		if result.error == .None {
			sync.atomic_store_explicit(&r.edid.verification_required, 0, .Relaxed)
			sync.atomic_store_explicit(&r.edid.notice, u32(EDID_Protocol_Error.None), .Relaxed)
		}
	}
	status := EDID_Availability.Ready
	if !result.mode_known do status = .Unknown
	if result.disposition == .Not_Applied && result.error != .None do status = .Error
	if edid_requires_reconnect(result.disposition) do status = .Reconnecting
	mode: Maybe(EDID_Mode)
	if result.mode_known do mode = result.mode
	renderer_set_edid_state(r, status, result.error, mode)
}

// An uncertain write leaves the range unknown until the next read; a readback
// mismatch stays visible as the error while the actual range is shown.
renderer_publish_color_range_result :: proc(r: ^Renderer, result: EDID_Result) {
	status := EDID_Availability.Ready
	if !result.color_range_known do status = .Unknown
	if result.color_range_disposition == .Not_Applied && result.color_range_error != .None do status = .Error
	range: Maybe(Color_Range)
	if result.color_range_known do range = result.color_range
	renderer_set_color_range_state(r, status, result.color_range_error, range)
}

renderer_handle_edid_result :: proc(r: ^Renderer, generation, request_id: u32) {
	if r == nil || sync.atomic_load_explicit(&r.edid.result_pending, .Acquire) == 0 do return
	// An old window message must not consume a newer session's pending result.
	if generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) ||
	   generation != sync.atomic_load_explicit(&r.edid.result_generation, .Relaxed) ||
	   request_id != sync.atomic_load_explicit(&r.edid.result_id, .Relaxed) {
		return
	}
	sync.atomic_store_explicit(&r.edid.result_pending, 0, .Release)
	error := EDID_Protocol_Error(sync.atomic_load_explicit(&r.edid.error, .Relaxed))
	disposition := EDID_Set_Disposition(sync.atomic_load_explicit(&r.edid.result_disposition, .Relaxed))
	if error != .None do fmt.eprintf("EDID operation result: request=%d error=%v disposition=%v\n", request_id, error, disposition)
	if edid_requires_reconnect(disposition) {
		sync.atomic_store_explicit(&r.edid.restore_pending, 1, .Release)
		sync.atomic_store_explicit(&r.edid.status, u32(EDID_Availability.Reconnecting), .Release)
		if !renderer_request_reconnect(r, false) {
			sync.atomic_store_explicit(&r.edid.status, u32(EDID_Availability.Applied_Capture_Unavailable), .Release)
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
	sync.atomic_store_explicit(&r.edid.restore_pending, 0, .Release)
}

renderer_edid_capture_failed :: proc(r: ^Renderer, generation: u32) {
	if r == nil || generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) do return
	if sync.atomic_load_explicit(&r.edid.restore_pending, .Acquire) != 0 {
		sync.atomic_store_explicit(&r.edid.status, u32(EDID_Availability.Applied_Capture_Unavailable), .Release)
	}
}
