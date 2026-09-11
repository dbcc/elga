package main

import "core:sync"
import "core:time"

CAPTURE_HEALTH_STALL_COUNT :: 16
CAPTURE_HEALTH_STALL_NS :: i64(500*time.Millisecond)
CAPTURE_HEALTH_FPS_WINDOW_NS :: i64(500*time.Millisecond)

Capture_Stall_Kind :: enum {
	Capture,
	Presentation,
}

Capture_Stall :: struct {
	kind: Capture_Stall_Kind,
	at_ns: i64,
	duration_ms: f64,
	ongoing: bool,
}

Capture_Health_Totals :: struct {
	samples_received: u64,
	presented_frames: u64,
	busy_drops: u64,
	upload_errors: u64,
	source_errors: u64,
	recovery_requests: u64,
}

Capture_Health :: struct {
	// Capture-thread/callback counters. Access these only through atomic helpers.
	samples_received: u64,
	busy_drops: u64,
	upload_errors: u64,
	source_errors: u64,
	recovery_requests: u64,
	last_sample_ns: i64,
	// A rare completed sample gap is published without a lock or allocation.
	// The UI owns the history ring; this mailbox preserves a gap if it was busy.
	gap_version: u64,
	gap_duration_ns: i64,
	gap_end_ns: i64,

	// Everything below is owned by the window thread.
	presented_frames: u64,
	capture_fps: f64,
	present_fps: f64,
	sample_age_ms: f64,
	present_age_ms: f64,
	has_samples: bool,
	capture_stalled: bool,
	present_stalled: bool,
	stalls: [CAPTURE_HEALTH_STALL_COUNT]Capture_Stall,
	stall_count: int,
	stall_next: int,
	capture_stall_index: int,
	present_stall_index: int,
	monitoring: bool,
	monitor_start_ns: i64,
	fps_start_ns: i64,
	fps_sample_count: u64,
	fps_present_count: u64,
	last_present_ns: i64,
	last_present_samples: u64,
	seen_gap_version: u64,
}

capture_health_now_ns :: proc() -> i64 {
	return i64(time.tick_diff({}, time.tick_now()))
}

capture_health_totals :: proc(h: ^Capture_Health) -> Capture_Health_Totals {
	return {
		samples_received = sync.atomic_load_explicit(&h.samples_received, .Relaxed),
		presented_frames = h.presented_frames,
		busy_drops = sync.atomic_load_explicit(&h.busy_drops, .Relaxed),
		upload_errors = sync.atomic_load_explicit(&h.upload_errors, .Relaxed),
		source_errors = sync.atomic_load_explicit(&h.source_errors, .Relaxed),
		recovery_requests = sync.atomic_load_explicit(&h.recovery_requests, .Relaxed),
	}
}

capture_health_note_sample :: proc(h: ^Capture_Health, now_ns := i64(-1)) {
	now_ns := capture_health_now_ns() if now_ns < 0 else now_ns
	previous := sync.atomic_exchange_explicit(&h.last_sample_ns, now_ns, .Acq_Rel)
	sync.atomic_add_explicit(&h.samples_received, 1, .Relaxed)
	if previous <= 0 || now_ns-previous < CAPTURE_HEALTH_STALL_NS do return
	// Source Reader callbacks are serialized by their existing session mutex.
	sync.atomic_add_explicit(&h.gap_version, 1, .Acq_Rel)
	sync.atomic_store_explicit(&h.gap_duration_ns, now_ns-previous, .Relaxed)
	sync.atomic_store_explicit(&h.gap_end_ns, now_ns, .Relaxed)
	sync.atomic_add_explicit(&h.gap_version, 1, .Release)
}

capture_health_note_recovery :: proc(h: ^Capture_Health) {
	sync.atomic_add_explicit(&h.recovery_requests, 1, .Relaxed)
}

// UI thread only. Keep app-session counters/history across mode changes,
// reconnects and minimize; never count time intentionally stopped as a stall.
capture_health_reset_timing :: proc(r: ^Renderer, now_ns := i64(-1)) {
	now_ns := capture_health_now_ns() if now_ns < 0 else now_ns
	h := &r.health
	if h.capture_stalled do h.stalls[h.capture_stall_index].ongoing = false
	if h.present_stalled do h.stalls[h.present_stall_index].ongoing = false
	h.capture_stalled, h.present_stalled = false, false
	h.has_samples = false
	h.monitoring = false
	h.monitor_start_ns, h.fps_start_ns = now_ns, now_ns
	h.capture_fps, h.present_fps = 0, 0
	h.sample_age_ms, h.present_age_ms = 0, 0
	h.last_present_ns = 0
	h.fps_sample_count = sync.atomic_load_explicit(&h.samples_received, .Relaxed)
	h.fps_present_count = h.presented_frames
	h.last_present_samples = h.fps_sample_count
	h.seen_gap_version = sync.atomic_load_explicit(&h.gap_version, .Acquire)
	sync.atomic_store_explicit(&h.last_sample_ns, 0, .Release)
}

capture_health_add_stall :: proc(h: ^Capture_Health, kind: Capture_Stall_Kind, at_ns, duration_ns: i64, ongoing: bool) -> int {
	index := h.stall_next
	if h.capture_stalled && h.capture_stall_index == index do h.capture_stalled = false
	if h.present_stalled && h.present_stall_index == index do h.present_stalled = false
	h.stalls[index] = {kind, at_ns, f64(max(duration_ns, 0))/f64(time.Millisecond), ongoing}
	h.stall_next = (index+1)%len(h.stalls)
	h.stall_count = min(h.stall_count+1, len(h.stalls))
	return index
}

capture_health_read_gap :: proc(h: ^Capture_Health) {
	version := sync.atomic_load_explicit(&h.gap_version, .Acquire)
	if version%2 != 0 || version == h.seen_gap_version do return
	duration := sync.atomic_load_explicit(&h.gap_duration_ns, .Relaxed)
	end := sync.atomic_load_explicit(&h.gap_end_ns, .Relaxed)
	sync.atomic_thread_fence(.Acquire)
	if version != sync.atomic_load_explicit(&h.gap_version, .Acquire) do return
	h.seen_gap_version = version
	start := end-duration
	if start < h.monitor_start_ns do return
	if h.capture_stalled && h.stalls[h.capture_stall_index].at_ns == start {
		stall := &h.stalls[h.capture_stall_index]
		stall.duration_ms, stall.ongoing = f64(duration)/f64(time.Millisecond), false
		h.capture_stalled = false
	} else {
		capture_health_add_stall(h, .Capture, start, duration, false)
	}
}

// Call from the UI timer even while video is stopped. Arrival FPS describes
// samples Windows delivered to this app; it cannot measure driver/device drops.
capture_health_update :: proc(r: ^Renderer, now_ns := i64(-1)) {
	now_ns := capture_health_now_ns() if now_ns < 0 else now_ns
	h := &r.health
	active := r.reconnect_thread == nil && sync.atomic_load_explicit(&r.capture_running, .Acquire) &&
		sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0 &&
		sync.atomic_load_explicit(&r.edid_operation_active, .Acquire) == 0 && !r.capture_suspended
	if !active {
		if h.monitoring do capture_health_reset_timing(r, now_ns)
		return
	}
	samples := sync.atomic_load_explicit(&h.samples_received, .Relaxed)
	if !h.monitoring {
		h.monitoring = true
		h.monitor_start_ns, h.fps_start_ns = now_ns, now_ns
		h.fps_sample_count, h.fps_present_count = samples, h.presented_frames
	}
	capture_health_read_gap(h)
	last_sample := sync.atomic_load_explicit(&h.last_sample_ns, .Acquire)
	h.has_samples = last_sample > 0
	sample_start := max(last_sample, h.monitor_start_ns)
	// Restart the presentation wait after a source gap so one source pause is
	// not also reported as a window/GPU stall.
	present_start := max(h.last_present_ns, h.monitor_start_ns, sync.atomic_load_explicit(&h.gap_end_ns, .Relaxed))
	sample_age := max(now_ns-sample_start, 0)
	present_age := max(now_ns-present_start, 0)
	h.sample_age_ms, h.present_age_ms = f64(sample_age)/f64(time.Millisecond), f64(present_age)/f64(time.Millisecond)
	if sample_age >= CAPTURE_HEALTH_STALL_NS {
		if !h.capture_stalled {
			h.capture_stall_index = capture_health_add_stall(h, .Capture, sample_start, sample_age, true)
			h.capture_stalled = true
		} else {
			h.stalls[h.capture_stall_index].duration_ms = h.sample_age_ms
		}
	} else if h.capture_stalled {
		stall := &h.stalls[h.capture_stall_index]
		stall.duration_ms = f64(max(last_sample-stall.at_ns, 0))/f64(time.Millisecond)
		stall.ongoing = false
		h.capture_stalled = false
	}
	// A stopped source also stops presentation; record its cause once.
	if present_age >= CAPTURE_HEALTH_STALL_NS && !h.capture_stalled && last_sample > 0 && samples-h.last_present_samples > 1 {
		if !h.present_stalled {
			h.present_stall_index = capture_health_add_stall(h, .Presentation, present_start, present_age, true)
			h.present_stalled = true
		} else {
			h.stalls[h.present_stall_index].duration_ms = h.present_age_ms
		}
	}
	elapsed := now_ns-h.fps_start_ns
	if elapsed >= CAPTURE_HEALTH_FPS_WINDOW_NS {
		h.capture_fps = f64(samples-h.fps_sample_count)*f64(time.Second)/f64(elapsed)
		h.present_fps = f64(h.presented_frames-h.fps_present_count)*f64(time.Second)/f64(elapsed)
		h.fps_start_ns = now_ns
		h.fps_sample_count, h.fps_present_count = samples, h.presented_frames
	}
}

// UI thread only, after a successful Present of a new video sequence.
capture_health_mark_present :: proc(r: ^Renderer, now_ns := i64(-1)) {
	now_ns := capture_health_now_ns() if now_ns < 0 else now_ns
	h := &r.health
	samples := sync.atomic_load_explicit(&h.samples_received, .Relaxed)
	present_start := max(h.last_present_ns, sync.atomic_load_explicit(&h.gap_end_ns, .Relaxed))
	if h.present_stalled {
		stall := &h.stalls[h.present_stall_index]
		stall.duration_ms = f64(max(now_ns-stall.at_ns, 0))/f64(time.Millisecond)
		stall.ongoing = false
		h.present_stalled = false
	} else if h.monitoring && h.last_present_ns > 0 && now_ns-present_start >= CAPTURE_HEALTH_STALL_NS && samples-h.last_present_samples > 1 {
		capture_health_add_stall(h, .Presentation, present_start, now_ns-present_start, false)
	}
	h.presented_frames += 1
	h.last_present_ns, h.last_present_samples = now_ns, samples
	h.present_age_ms = 0
}
