package main

import "base:runtime"
import "core:c"
import "core:os"
import "core:testing"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import stbi "vendor:stb/image"

@(test)
screenshot_native_color_orientation_and_padding_test :: proc(t: ^testing.T) {
	// Device alpha and padded bytes must never make it into the opaque image.
	source := [24]u8{3, 2, 1, 0, 6, 5, 4, 128, 99, 99, 99, 99, 9, 8, 7, 255, 12, 11, 10, 0, 77, 77, 77, 77}
	for flipped in ([2]bool{false, true}) {
		actual: [12]u8
		for y in 0..<u32(2) do screenshot_copy_rgb_row(actual[int(y)*6:][:6], &source[0], 12, 2, 2, y, flipped)
		expected := [12]u8{7, 8, 9, 10, 11, 12, 1, 2, 3, 4, 5, 6} if flipped else [12]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12}
		for value, index in actual do testing.expect_value(t, value, expected[index])
	}
}

@(test)
screenshot_rejects_invalid_or_excessive_dimensions_test :: proc(t: ^testing.T) {
	testing.expect(t, screenshot_dimensions_valid(3840, 2160))
	testing.expect(t, screenshot_dimensions_valid(7680, 4320))
	for dimensions in ([5][2]u32{{0, 2160}, {3840, 0}, {0xffffffff, 2}, {16384, 16384}, {16385, 1}}) {
		testing.expect(t, !screenshot_dimensions_valid(dimensions[0], dimensions[1]))
	}
}

@(test)
screenshot_requests_are_bounded_and_no_frame_is_not_saved_test :: proc(t: ^testing.T) {
	s: Screenshot_State
	r: Renderer
	testing.expect(t, !screenshot_request(&s, &r))
	testing.expect_value(t, s.status, Screenshot_Status.Unavailable)
	testing.expect(t, !screenshot_update(&s, &r))
	for status in ([3]Screenshot_Status{.Waiting, .Reading, .Saving}) {
		s.status = status
		testing.expect(t, !screenshot_request(&s, &r))
		testing.expect_value(t, s.status, status)
	}
	// A reconnect cancels a queued readback before any renderer pointers are
	// accessed. No old frame can be labelled as a screenshot of a new session.
	s.status = .Waiting
	s.capture_generation = 1
	r.ready = true
	r.capture_ready = 1
	r.capture_generation = 2
	testing.expect(t, screenshot_update(&s, &r))
	testing.expect_value(t, s.error, Screenshot_Error.Capture_Changed)
	screenshot_destroy(&s)
	testing.expect_value(t, s.status, Screenshot_Status.Idle)
}

@(test)
screenshot_file_collision_preserves_existing_capture_test :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "elga-shot-ü-*", context.allocator)
	if !testing.expect(t, directory_error == nil) do return
	defer delete(directory)
	defer os.remove(directory)
	stamp := time.now()
	first, first_path := screenshot_open_unique(directory, stamp)
	if !testing.expect(t, first != win32.INVALID_HANDLE) do return
	defer delete(first_path, runtime.heap_allocator())
	defer os.remove(first_path)
	sentinel := [4]u8{1, 2, 3, 4}
	written: u32
	testing.expect(t, bool(win32.WriteFile(first, &sentinel[0], len(sentinel), &written, nil)))
	win32.CloseHandle(first)
	second, second_path := screenshot_open_unique(directory, stamp)
	if !testing.expect(t, second != win32.INVALID_HANDLE) do return
	win32.CloseHandle(second)
	defer delete(second_path, runtime.heap_allocator())
	defer os.remove(second_path)
	testing.expect(t, first_path != second_path)
	data, read_error := os.read_entire_file(first_path, context.allocator)
	if !testing.expect(t, read_error == nil) do return
	defer delete(data)
	if !testing.expect_value(t, len(data), len(sentinel)) do return
	for value, index in data do testing.expect_value(t, value, sentinel[index])
}

@(test)
screenshot_png_native_dimensions_and_lossless_pixels_test :: proc(t: ^testing.T) {
	directory, directory_error := os.make_directory_temp("", "elga-png-*", context.allocator)
	if !testing.expect(t, directory_error == nil) do return
	defer delete(directory)
	defer os.remove(directory)
	job: Screenshot_Job
	job.file, job.path = screenshot_open_unique(directory, time.now())
	if !testing.expect(t, job.file != win32.INVALID_HANDLE) do return
	defer delete(job.path, runtime.heap_allocator())
	defer os.remove(job.path)
	job.write_ok = true
	pixels := [18]u8{255, 0, 0, 0, 255, 0, 0, 0, 255, 0, 0, 0, 128, 129, 130, 255, 255, 255}
	result := stbi.write_png_to_func(screenshot_write_callback, &job, 3, 2, 3, &pixels[0], 9)
	win32.CloseHandle(job.file)
	if !testing.expect(t, result != 0 && job.write_ok) do return
	encoded, read_error := os.read_entire_file(job.path, context.allocator)
	if !testing.expect(t, read_error == nil) do return
	defer delete(encoded)
	width, height, channels: c.int
	decoded := stbi.load_from_memory(raw_data(encoded), c.int(len(encoded)), &width, &height, &channels, 3)
	if !testing.expect(t, decoded != nil) do return
	defer stbi.image_free(decoded)
	testing.expect_value(t, width, c.int(3))
	testing.expect_value(t, height, c.int(2))
	testing.expect_value(t, channels, c.int(3))
	for value, index in pixels do testing.expect_value(t, decoded[index], value)
}

when #config(ELGA_GPU_TESTS, false) {
	@(test)
	screenshot_gpu_copies_native_surface_without_display_scaling_test :: proc(t: ^testing.T) {
		screenshot_gpu_copies_native_surface_without_display_scaling(t)
	}
}

screenshot_gpu_copies_native_surface_without_display_scaling :: proc(t: ^testing.T) {
	r: Renderer
	defer renderer_destroy(&r)
	levels := [1]d3d11.FEATURE_LEVEL{._11_0}
	if !testing.expect(t, !failed(d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, &levels[0], 1, d3d11.SDK_VERSION, &r.device_11, nil, &r.context_11))) do return
	if !testing.expect(t, !failed(d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, &levels[0], 1, d3d11.SDK_VERSION, &r.capture_device_11, nil, &r.capture_context_11))) do return
	if !testing.expect(t, video_resources_create(&r, .RGB24, 4, 2)) do return
	r.ready = true
	r.capture_ready = 1
	r.width, r.height = 640, 480
	r.video_sequence = 1
	r.video_vertical_flip = 1
	source := [32]u8{3, 2, 1, 0, 6, 5, 4, 0, 9, 8, 7, 0, 12, 11, 10, 0, 15, 14, 13, 0, 18, 17, 16, 0, 21, 20, 19, 0, 24, 23, 22, 0}
	if !testing.expect(t, video_mutex_acquire(r.capture_mutex, 0)) do return
	r.capture_context_11.UpdateSubresource(r.capture_context_11, cast(^d3d11.IResource)r.processed_texture, 0, nil, &source[0], 16, 0)
	r.capture_mutex.ReleaseSync(r.capture_mutex, 1)
	r.capture_context_11.Flush(r.capture_context_11)
	s: Screenshot_State
	defer screenshot_destroy(&s)
	if !testing.expect(t, screenshot_request(&s, &r)) do return
	start := time.now()
	for s.status == .Waiting && time.since(start) < SCREENSHOT_READBACK_TIMEOUT {
		screenshot_update(&s, &r)
		if s.status == .Waiting do time.sleep(time.Millisecond)
	}
	if !testing.expect_value(t, s.status, Screenshot_Status.Reading) do return
	testing.expect_value(t, s.width, u32(4))
	testing.expect_value(t, s.height, u32(2))
	testing.expect(t, s.vertical_flip)
	// Inspect only the private GPU copy, without saving a test image in the
	// user's Pictures folder or asking the screenshot worker to write it.
	mapped: d3d11.MAPPED_SUBRESOURCE
	hr := dxgi.ERROR_WAS_STILL_DRAWING
	for hr == dxgi.ERROR_WAS_STILL_DRAWING && time.since(start) < SCREENSHOT_READBACK_TIMEOUT {
		hr = s.context_11.Map(s.context_11, cast(^d3d11.IResource)s.staging, 0, .READ, {.DO_NOT_WAIT}, &mapped)
		if hr == dxgi.ERROR_WAS_STILL_DRAWING do time.sleep(time.Millisecond)
	}
	if !testing.expect(t, !failed(hr)) do return
	s.mapped = true
	readback := cast([^]u8)mapped.pData
	for y in 0..<2 {
		row := readback[y*int(mapped.RowPitch):y*int(mapped.RowPitch)+16]
		for value, x in row do testing.expect_value(t, value, source[y*16+x])
	}
	// Screenshot readback is observational: the frame remains ready for
	// the renderer, and capture cannot replace it before presentation.
	if !testing.expect(t, video_mutex_acquire(r.render_mutex, 1)) do return
	r.render_mutex.ReleaseSync(r.render_mutex, 1)
	// Retained context/staging refs stay valid across a capture reconnect.
	video_resources_release(&r)
	r.capture_generation += 1
	testing.expect(t, screenshot_update(&s, &r))
	testing.expect_value(t, s.error, Screenshot_Error.Capture_Changed)
	testing.expect(t, s.context_11 == nil && s.staging == nil && !s.mapped)
}
