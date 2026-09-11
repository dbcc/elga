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
		{.RGB24, 4, 4, 32, 112, 32, true},
		{.RGB24, 4, 4, 32, 111, 0, false},
		{.NV12, 4, 4, 16, 84, 16, true},
		{.NV12, 4, 4, 16, 83, 0, false},
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
capture_upload_2d_bounds_test :: proc(t: ^testing.T) {
	pixels: [192]u8
	start := &pixels[0]
	Case :: struct {
		format: Capture_Format,
		width, height: u32,
		stride: i32,
		scanline_offset: int,
		length: u32,
		valid: bool,
		data_offset: int,
		pitch: u32,
	}
	cases := []Case{
		{.RGB24, 4, 4, 32, 8, 136, true, 8, 32},
		{.RGB24, 4, 4, -32, 104, 136, true, 8, 32},
		{.NV12, 4, 4, 16, 8, 104, true, 8, 16},
		{.RGB24, 4, 4, 32, 8, 120, true, 8, 32},
		{.RGB24, 4, 4, 32, 8, 119, false, 0, 0},
		{.RGB24, 4, 4, -32, 95, 128, false, 0, 0},
		{.RGB24, 4, 4, 32, 129, 128, false, 0, 0},
		{.RGB24, 4, 4, 0, 0, 128, false, 0, 0},
		{.NV12, 4, 4, -16, 48, 96, false, 0, 0},
		{.RGB24, 4, 0xffffffff, -2147483648, 0, 128, false, 0, 0},
	}
	for c in cases {
		data, pitch, valid := capture_upload_2d_data(c.format, c.width, c.height, c.stride, &pixels[c.scanline_offset], start, c.length)
		testing.expect_value(t, valid, c.valid)
		testing.expect_value(t, pitch, c.pitch)
		if c.valid {
			testing.expect(t, data == &pixels[c.data_offset])
		} else {
			testing.expect(t, data == nil)
		}
	}
	_, _, valid := capture_upload_2d_data(.RGB24, 4, 4, 32, &pixels[0], &pixels[1], 128)
	testing.expect(t, !valid)
	_, _, valid = capture_upload_2d_data(.RGB24, 4, 4, 32, nil, start, 128)
	testing.expect(t, !valid)
}

@(test)
capture_rejected_buffer_cleanup_test :: proc(t: ^testing.T) {
	if !testing.expect(t, !failed(win32.CoInitializeEx(nil, .MULTITHREADED))) do return
	defer win32.CoUninitialize()
	if !testing.expect(t, !failed(MFStartup(MF_VERSION, MFSTARTUP_FULL))) do return
	defer MFShutdown()
	// Real software buffers exercise COM ownership without a capture card or GPU.
	// Each undersized frame must release its temporary references and 2D lock.
	r := Renderer{capture_format = .NV12, capture_width = 64, capture_height = 36}
	for iteration in 0..<32 {
		buffer: ^IMFMediaBuffer
		sample: ^IMFSample
		defer {
			if sample != nil {
				unknown := cast(^win32.IUnknown)sample
				testing.expect_value(t, unknown.Release(unknown), win32.ULONG(0))
			}
			if buffer != nil {
				unknown := cast(^win32.IUnknown)buffer
				testing.expect_value(t, unknown.Release(unknown), win32.ULONG(0))
			}
		}
		if iteration%2 == 0 {
			if !testing.expect(t, !failed(MFCreateMemoryBuffer(32*18*3/2, &buffer))) do return
			if !testing.expect(t, !failed(buffer.SetCurrentLength(buffer, 32*18*3/2))) do return
		} else {
			if !testing.expect(t, !failed(MFCreate2DMediaBuffer(32, 18, MFVideoFormat_NV12.Data1, false, &buffer))) do return
		}
		if !testing.expect(t, !failed(MFCreateSample(&sample))) do return
		if !testing.expect(t, !failed(sample.AddBuffer(sample, buffer))) do return
		testing.expect(t, !capture_upload_sample(&r, sample))
		// A surviving Lock2DSize prevents switching to the contiguous Lock API.
		data: ^u8
		if testing.expect(t, !failed(buffer.Lock(buffer, &data, nil, nil))) {
			buffer.Unlock(buffer)
		}
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
	// High-rate 4K capture modes can duplicate a 60 Hz HDMI signal. Automatic
	// selection prefers a native 60 Hz mode. Lower resolutions retain the
	// highest-rate policy.
	uhd_144 := Capture_Mode{width = 3840, height = 2160, fps_num = 144, fps_den = 1}
	uhd_120 := Capture_Mode{width = 3840, height = 2160, fps_num = 120, fps_den = 1}
	uhd_60 := Capture_Mode{width = 3840, height = 2160, fps_num = 60, fps_den = 1}
	testing.expect(t, mode_better(uhd_60, uhd_144, true))
	testing.expect(t, mode_better(uhd_120, uhd_144, true))
	testing.expect(t, !mode_better(uhd_144, uhd_60, true))
	testing.expect(t, mode_better(uhd_144, uhd_60))
	hd_60 := Capture_Mode{width = 1920, height = 1080, fps_num = 60, fps_den = 1}
	hd_120 := Capture_Mode{width = 1920, height = 1080, fps_num = 120, fps_den = 1}
	testing.expect(t, mode_better(hd_120, hd_60))
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
