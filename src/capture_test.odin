package main

import "base:runtime"
import "core:sync"
import "core:testing"
import win32 "core:sys/windows"
import dxgi "vendor:directx/dxgi"

Test_Keyed_Mutex :: struct {
	using vtable: ^dxgi.IKeyedMutex_VTable,
	result: win32.HRESULT,
	releases: int,
	released_key: u64,
}

test_mutex_release :: proc "system" (this: ^dxgi.IKeyedMutex, key: u64) -> win32.HRESULT {
	mutex := cast(^Test_Keyed_Mutex)this
	mutex.releases += 1
	mutex.released_key = key
	return 0
}

test_empty_sample :: proc "system" (this: ^IMFSample, count: ^u32) -> win32.HRESULT {
	count^ = 0
	return 0
}

@(test)
capture_frame_drop_cleanup_test :: proc(t: ^testing.T) {
	mutex_vtable := dxgi.IKeyedMutex_VTable{AcquireSync = test_mutex_acquire, ReleaseSync = test_mutex_release}
	mutex := Test_Keyed_Mutex{vtable = &mutex_vtable, result = win32.HRESULT(win32.WAIT_TIMEOUT)}
	r := Renderer{capture_mutex = cast(^dxgi.IKeyedMutex)&mutex}
	// A busy frame must not dereference the sample or release an unowned mutex.
	capture_copy_sample(&r, nil)
	testing.expect_value(t, mutex.releases, 0)
	testing.expect_value(t, r.video_sequence, u64(0))

	sample_vtable := IMFSample_VTable{GetBufferCount = test_empty_sample}
	sample := IMFSample{vtable = &sample_vtable}
	mutex.result = 0
	capture_copy_sample(&r, &sample)
	testing.expect_value(t, mutex.releases, 1)
	testing.expect_value(t, mutex.released_key, u64(0))
	testing.expect_value(t, r.video_sequence, u64(0))
}

test_mutex_acquire :: proc "system" (this: ^dxgi.IKeyedMutex, key: u64, timeout: u32) -> win32.HRESULT {
	return (cast(^Test_Keyed_Mutex)this).result
}

@(test)
video_mutex_results_test :: proc(t: ^testing.T) {
	vtable := dxgi.IKeyedMutex_VTable{AcquireSync = test_mutex_acquire}
	mutex := Test_Keyed_Mutex{vtable = &vtable}
	results := []win32.HRESULT{0, 1, win32.HRESULT(win32.WAIT_TIMEOUT), 0x80 /* WAIT_ABANDONED */, -1}
	for result in results {
		mutex.result = result
		testing.expect_value(t, video_mutex_acquire(cast(^dxgi.IKeyedMutex)&mutex, 0), result == 0)
	}
	testing.expect(t, !video_mutex_acquire(nil, 0))
}

@(test)
capture_upload_bounds_test :: proc(t: ^testing.T) {
	Case :: struct {
		format: Capture_Format,
		width, height: u32,
		stride: i32,
		length, pitch: u32,
		valid: bool,
	}
	cases := []Case{
		{.NV12, 1920, 1080, 0, 3110400, 1920, true},
		{.P010, 1920, 1080, 0, 6220800, 3840, true},
		{.YUY2, 1920, 1080, 0, 4147200, 3840, true},
		{.RGB24, 1920, 1080, -7680, 8294400, 7680, true},
		{.I420, 1920, 1080, 2048, 3317760, 2048, true},
		{.MJPEG, 1920, 1080, 0, 3110399, 0, false},
		{.NV12, 1920, 1080, -1920, 3110400, 0, false},
		{.NV12, 1920, 1081, 0, 4000000, 0, false},
		{.YUY2, 1919, 1080, 0, 4147200, 0, false},
		{.RGB24, 1920, 1080, 100, 8294400, 0, false},
		{.RGB24, 1920, 1080, -2147483648, 0xffffffff, 0, false},
		{.RGB24, 0xffffffff, 0xffffffff, 0, 0xffffffff, 0, false},
		{.NV12, 0, 1080, 0, 3110400, 0, false},
		{.NV12, 1920, 0, 0, 3110400, 0, false},
	}
	for c in cases {
		pitch, valid := capture_upload_pitch(c.format, c.width, c.height, c.stride, c.length)
		testing.expect_value(t, valid, c.valid)
		testing.expect_value(t, pitch, c.pitch)
	}
}

@(test)
capture_callback_lifetime_test :: proc(t: ^testing.T) {
	// COM owns its reference after the capture thread drops its initial one.
	callback := new(Source_Reader_Callback, runtime.default_context().allocator)
	callback^ = {vtable = &source_reader_callback_vtable, ref_count = 1}
	callback.flush_event = win32.CreateEventW(nil, false, false, nil)
	testing.expect(t, callback.flush_event != nil)
	unknown := cast(^win32.IUnknown)callback
	testing.expect_value(t, source_reader_add_ref(unknown), win32.ULONG(2))
	r: Renderer
	callback.renderer = &r
	source_reader_detach(callback)
	testing.expect(t, callback.renderer == nil && callback.reader == nil)
	testing.expect_value(t, source_reader_release(unknown), win32.ULONG(1))
	iface := cast(^IMFSourceReaderCallback)callback
	testing.expect_value(t, source_reader_on_read_sample(iface, 0, 0, 0, 0, nil), win32.HRESULT(0))
	source_reader_on_flush(iface, 0)
	testing.expect_value(t, win32.WaitForSingleObject(callback.flush_event, 0), win32.DWORD(win32.WAIT_OBJECT_0))
	testing.expect_value(t, source_reader_release(unknown), win32.ULONG(0))
}

@(test)
capture_flush_wait_test :: proc(t: ^testing.T) {
	r: Renderer
	r.capture_event = win32.CreateEventW(nil, false, false, nil)
	callback: Source_Reader_Callback
	callback.flush_event = win32.CreateEventW(nil, false, true, nil)
	defer win32.CloseHandle(r.capture_event)
	defer win32.CloseHandle(callback.flush_event)
	testing.expect(t, r.capture_event != nil && callback.flush_event != nil)
	sync.atomic_store_explicit(&r.capture_running, true, .Release)
	testing.expect(t, capture_wait_for_flush(&r, &callback))
	sync.atomic_store_explicit(&r.capture_running, false, .Release)
	testing.expect(t, !capture_wait_for_flush(&r, &callback))
}

@(test)
capture_mode_selection_test :: proc(t: ^testing.T) {
	r: Renderer
	r.source_modes[0] = {width = 1920, height = 1080, fps_num = 60, fps_den = 1, format = .NV12}
	r.source_modes[1] = {width = 3840, height = 2160, fps_num = 60000, fps_den = 1001, format = .P010}
	r.source_modes[2] = {width = 3840, height = 2160, fps_num = 60, fps_den = 1, format = .YUY2}
	r.source_modes[3] = {width = 3840, height = 2160, fps_num = 120, fps_den = 1, format = .MJPEG}
	r.source_modes[4] = r.source_modes[2]
	r.source_modes[4].format = .NV12
	sync.atomic_store_explicit(&r.source_mode_count, 5, .Release)
	format, found := capture_pick_auto_format(&r, 0, 0)
	testing.expect(t, found)
	testing.expect_value(t, format, Capture_Format.YUY2)
	format, found = capture_pick_auto_format(&r, 1920, 1080)
	testing.expect(t, found)
	testing.expect_value(t, format, Capture_Format.NV12)
	_, found = capture_pick_auto_format(&r, 1280, 720)
	testing.expect(t, !found)
	// Equal modes preserve native driver order; comparison uses exact fractions.
	testing.expect(t, !mode_better(r.source_modes[4], r.source_modes[2]))
	testing.expect(t, mode_better(r.source_modes[2], r.source_modes[1]))
}

@(test)
capture_failure_while_minimized_test :: proc(t: ^testing.T) {
	r := Renderer{
		ready = true, capture_suspended = true, capture_generation = 3,
		capture_format = .P010, last_working_valid = true, last_working_format = .NV12,
	}
	// A queued failure must not recreate GPU resources or start a hidden capture.
	renderer_handle_capture_failure(&r, 3)
	testing.expect(t, r.capture_suspended && r.last_working_valid)
	testing.expect_value(t, r.capture_format, Capture_Format.P010)
	testing.expect(t, r.capture_thread == nil && r.capture_texture == nil)
}
