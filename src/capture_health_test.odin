package main

import "core:sync"
import "core:testing"
import "core:time"
import win32 "core:sys/windows"
import dxgi "vendor:directx/dxgi"

@(test)
capture_health_observed_rates_test :: proc(t: ^testing.T) {
	r := Renderer{capture_running = true, capture_ready = 1, capture_fps_num = 144, capture_fps_den = 1}
	start := i64(time.Second)
	capture_health_reset_timing(&r, start)
	capture_health_update(&r, start)
	for frame in 1..=60 {
		now := start+i64(frame)*i64(10*time.Millisecond)
		capture_health_note_sample(&r.health, now)
		if frame%2 == 0 do capture_health_mark_present(&r, now)
	}
	capture_health_update(&r, start+i64(600*time.Millisecond))
	// Measures delivered samples and new presentations, not the requested 144 Hz.
	testing.expect_value(t, r.health.capture_fps, f64(100))
	testing.expect_value(t, r.health.present_fps, f64(50))
	totals := capture_health_totals(&r.health)
	testing.expect_value(t, totals.samples_received, u64(60))
	testing.expect_value(t, totals.presented_frames, u64(30))
	testing.expect_value(t, r.health.stall_count, 0)
}

@(test)
capture_health_drop_and_error_accounting_test :: proc(t: ^testing.T) {
	vtable := dxgi.IKeyedMutex_VTable{AcquireSync = test_mutex_acquire, ReleaseSync = test_mutex_release}
	mutex := Test_Keyed_Mutex{vtable = &vtable, result = win32.HRESULT(win32.WAIT_TIMEOUT)}
	r := Renderer{capture_running = true, capture_mutex = cast(^dxgi.IKeyedMutex)&mutex}
	capture_health_note_sample(&r.health, i64(time.Second))
	capture_copy_sample(&r, nil)
	mutex.result = 0
	sample_vtable := IMFSample_VTable{GetBufferCount = test_empty_sample}
	sample := IMFSample{vtable = &sample_vtable}
	capture_health_note_sample(&r.health, i64(time.Second)+1)
	capture_copy_sample(&r, &sample)
	callback := Source_Reader_Callback{renderer = &r}
	iface := cast(^IMFSourceReaderCallback)&callback
	source_reader_on_read_sample(iface, -1, 0, 0, 0, nil)
	source_reader_on_read_sample(iface, -1, 0, 0, 0, nil)
	totals := capture_health_totals(&r.health)
	testing.expect_value(t, totals.samples_received, u64(2))
	testing.expect_value(t, totals.busy_drops, u64(1))
	testing.expect_value(t, totals.upload_errors, u64(1))
	testing.expect_value(t, totals.source_errors, u64(2))
	testing.expect_value(t, totals.recovery_requests, u64(1))
	sync.atomic_store_explicit(&r.capture_refresh, 0, .Release)
	capture_request_refresh(&r)
	testing.expect_value(t, capture_health_totals(&r.health).recovery_requests, u64(2))
}

@(test)
capture_health_source_stall_is_recorded_once_test :: proc(t: ^testing.T) {
	r := Renderer{capture_running = true, capture_ready = 1}
	start := i64(time.Second)
	first := start+i64(10*time.Millisecond)
	capture_health_update(&r, start)
	capture_health_note_sample(&r.health, first)
	capture_health_mark_present(&r, first)
	capture_health_update(&r, first+i64(600*time.Millisecond))
	testing.expect(t, r.health.capture_stalled && !r.health.present_stalled)
	testing.expect_value(t, r.health.stall_count, 1)
	capture_health_update(&r, first+i64(700*time.Millisecond))
	testing.expect_value(t, r.health.stall_count, 1)
	testing.expect_value(t, r.health.stalls[0].duration_ms, f64(700))
	resumed := first+i64(800*time.Millisecond)
	capture_health_note_sample(&r.health, resumed)
	capture_health_update(&r, resumed)
	capture_health_note_sample(&r.health, resumed+i64(10*time.Millisecond))
	capture_health_mark_present(&r, resumed+i64(10*time.Millisecond))
	testing.expect(t, !r.health.capture_stalled && !r.health.present_stalled)
	testing.expect_value(t, r.health.stall_count, 1)
	testing.expect_value(t, r.health.stalls[0].kind, Capture_Stall_Kind.Capture)
	testing.expect_value(t, r.health.stalls[0].duration_ms, f64(800))
	testing.expect(t, !r.health.stalls[0].ongoing)
}

@(test)
capture_health_gap_survives_delayed_ui_and_history_is_bounded_test :: proc(t: ^testing.T) {
	r := Renderer{capture_running = true, capture_ready = 1}
	start := i64(time.Second)
	capture_health_update(&r, start)
	for gap in 0..<CAPTURE_HEALTH_STALL_COUNT+5 {
		first := start+i64(gap+1)*i64(time.Second)
		// Each gap completes between UI updates; the callback mailbox preserves it.
		sync.atomic_store_explicit(&r.health.last_sample_ns, 0, .Release)
		capture_health_note_sample(&r.health, first)
		capture_health_note_sample(&r.health, first+i64(600*time.Millisecond))
		capture_health_mark_present(&r, first+i64(600*time.Millisecond))
		capture_health_update(&r, first+i64(610*time.Millisecond))
	}
	testing.expect_value(t, r.health.stall_count, CAPTURE_HEALTH_STALL_COUNT)
	testing.expect_value(t, r.health.stall_next, 5)
	newest := (r.health.stall_next+len(r.health.stalls)-1)%len(r.health.stalls)
	testing.expect_value(t, r.health.stalls[newest].kind, Capture_Stall_Kind.Capture)
	testing.expect_value(t, r.health.stalls[newest].duration_ms, f64(600))
	testing.expect(t, !r.health.stalls[newest].ongoing)
}

@(test)
capture_health_presentation_stall_and_pause_reset_test :: proc(t: ^testing.T) {
	r := Renderer{capture_running = true, capture_ready = 1}
	start := i64(time.Second)
	capture_health_update(&r, start)
	capture_health_note_sample(&r.health, start)
	capture_health_mark_present(&r, start)
	for frame in 1..=6 do capture_health_note_sample(&r.health, start+i64(frame)*i64(100*time.Millisecond))
	capture_health_update(&r, start+i64(600*time.Millisecond))
	testing.expect(t, r.health.present_stalled && !r.health.capture_stalled)
	testing.expect_value(t, r.health.stalls[0].kind, Capture_Stall_Kind.Presentation)
	capture_health_mark_present(&r, start+i64(610*time.Millisecond))
	testing.expect(t, !r.health.present_stalled)
	testing.expect_value(t, r.health.stalls[0].duration_ms, f64(610))
	totals_before := capture_health_totals(&r.health)
	r.capture_suspended = true
	capture_health_update(&r, start+i64(time.Second))
	capture_health_update(&r, start+i64(60*time.Second))
	r.capture_suspended = false
	capture_health_reset_timing(&r, start+i64(60*time.Second))
	capture_health_update(&r, start+i64(60*time.Second))
	capture_health_note_sample(&r.health, start+i64(60*time.Second)+1)
	capture_health_update(&r, start+i64(60*time.Second)+2)
	testing.expect(t, !r.health.capture_stalled && !r.health.present_stalled)
	testing.expect_value(t, r.health.stall_count, 1)
	testing.expect_value(t, r.health.capture_fps, f64(0))
	testing.expect_value(t, capture_health_totals(&r.health).samples_received, totals_before.samples_received+1)
	testing.expect_value(t, capture_health_totals(&r.health).presented_frames, totals_before.presented_frames)
}

@(test)
capture_health_ready_without_samples_is_not_signal_test :: proc(t: ^testing.T) {
	r := Renderer{capture_running = true, capture_ready = 1}
	start := i64(time.Second)
	capture_health_update(&r, start)
	capture_health_update(&r, start+CAPTURE_HEALTH_STALL_NS)
	testing.expect(t, r.health.capture_stalled)
	testing.expect(t, !r.health.present_stalled)
	testing.expect_value(t, r.health.capture_fps, f64(0))
	testing.expect_value(t, capture_health_totals(&r.health).samples_received, u64(0))
}
