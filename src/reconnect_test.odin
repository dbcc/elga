package main

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import win32 "core:sys/windows"
import dxgi "vendor:directx/dxgi"

Test_Reconnect_Capture :: struct {
	r: ^Renderer,
	stop_entered: win32.HANDLE,
	allow_stop: win32.HANDLE,
}

test_reconnect_capture_thread :: proc(t: ^thread.Thread) {
	fixture := cast(^Test_Reconnect_Capture)t.data
	win32.WaitForSingleObject(fixture.r.capture_event, win32.INFINITE)
	win32.SetEvent(fixture.stop_entered)
	win32.WaitForSingleObject(fixture.allow_stop, win32.INFINITE)
}

@(test)
reconnect_shutdown_is_async_and_minimize_cancels_restart_test :: proc(t: ^testing.T) {
	vt := dxgi.ISwapChain3_VTable{ResizeBuffers = test_renderer_resize_buffers}
	swap_chain := Test_Renderer_Swap_Chain{vtable = &vt}
	r := Renderer{
		ready = true, capture_running = true, capture_generation = 7,
		capture_format = .P010, requested_width = 1920, requested_height = 1080,
		resource_width = 1920, resource_height = 1080,
		swap_chain = cast(^dxgi.ISwapChain3)&swap_chain,
	}
	r.capture_event = win32.CreateEventW(nil, false, false, nil)
	fixture := Test_Reconnect_Capture{
		r = &r,
		stop_entered = win32.CreateEventW(nil, true, false, nil),
		allow_stop = win32.CreateEventW(nil, true, false, nil),
	}
	defer {
		win32.SetEvent(fixture.allow_stop)
		if r.reconnect_thread != nil {
			thread.join(r.reconnect_thread)
			thread.destroy(r.reconnect_thread)
			r.reconnect_thread = nil
		}
		capture_stop(&r)
		win32.CloseHandle(fixture.stop_entered)
		win32.CloseHandle(fixture.allow_stop)
	}
	if !testing.expect(t, r.capture_event != nil && fixture.stop_entered != nil && fixture.allow_stop != nil) do return
	r.capture_thread = thread.create(test_reconnect_capture_thread)
	if !testing.expect(t, r.capture_thread != nil) do return
	r.capture_thread.data = &fixture
	thread.start(r.capture_thread)
	// The caller must return even though source shutdown has not been released.
	if !testing.expect(t, renderer_request_reconnect(&r)) do return
	testing.expect_value(t, win32.WaitForSingleObject(fixture.stop_entered, 1000), win32.WAIT_OBJECT_0)
	testing.expect(t, r.reconnect_thread != nil)
	testing.expect(t, !renderer_update_reconnect(&r))
	testing.expect(t, !renderer_request_reconnect(&r))
	testing.expect_value(t, sync.atomic_load(&r.capture_generation), u32(8))
	testing.expect_value(t, r.capture_format, Capture_Format.P010)
	testing.expect_value(t, r.requested_width, u32(1920))
	testing.expect_value(t, r.requested_height, u32(1080))
	testing.expect_value(t, swap_chain.resize_count, 0)
	renderer_suspend_capture(&r)
	testing.expect(t, r.suspend_requested)
	testing.expect_value(t, swap_chain.resize_count, 0)
	win32.SetEvent(fixture.allow_stop)
	deadline := time.now()
	for sync.atomic_load_explicit(&r.reconnect_done, .Acquire) == 0 {
		if time.since(deadline) > time.Second {
			testing.expect(t, false, "Reconnect shutdown did not finish")
			return
		}
		time.sleep(time.Millisecond)
	}
	testing.expect(t, renderer_update_reconnect(&r))
	testing.expect(t, r.reconnect_thread == nil && r.capture_thread == nil)
	testing.expect(t, r.capture_suspended && !r.suspend_requested)
	testing.expect_value(t, swap_chain.resize_count, 1)
	testing.expect_value(t, sync.atomic_load(&r.capture_generation), u32(8))
}

@(test)
reconnect_rejects_unavailable_or_reentrant_requests_test :: proc(t: ^testing.T) {
	testing.expect(t, !renderer_request_reconnect(nil))
	r: Renderer
	testing.expect(t, !renderer_request_reconnect(&r))
	r.ready = true
	r.capture_suspended = true
	testing.expect(t, !renderer_request_reconnect(&r))
	r.capture_suspended = false
	r.drawing = true
	testing.expect(t, !renderer_request_reconnect(&r))
	testing.expect(t, !renderer_update_reconnect(&r))
	testing.expect_value(t, r.capture_generation, u32(0))
}
