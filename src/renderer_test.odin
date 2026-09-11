package main

import "core:testing"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"

@(test)
renderer_video_viewport_reserves_title_bar_without_cropping_test :: proc(t: ^testing.T) {
	windowed := video_viewport(1280, 762, 42)
	testing.expect_value(t, windowed, d3d11.VIEWPORT{TopLeftY = 42, Width = 1280, Height = 720, MaxDepth = 1})
	fullscreen := video_viewport(1920, 1080, 0)
	testing.expect_value(t, fullscreen, d3d11.VIEWPORT{Width = 1920, Height = 1080, MaxDepth = 1})
	// Revealing the fullscreen bar reduces the available image area; it must
	// preserve the full frame beneath the bar and center horizontal margins.
	visible := video_viewport(1920, 1080, 42)
	testing.expect_value(t, visible.TopLeftY, f32(42))
	testing.expect_value(t, visible.Height, f32(1038))
	testing.expect(t, abs(visible.Width-visible.Height*16/9) < 0.001)
	testing.expect(t, abs(visible.TopLeftX*2+visible.Width-1920) < 0.001)
	testing.expect(t, visible.TopLeftX > 0)
	// DPI scaling reserves physical pixels above an unchanged 1280x720 video.
	for dpi in ([4]u32{96, 120, 144, 192}) {
		inset := u32(title_bar_height_for_dpi(dpi))
		viewport := video_viewport(1280, 720+inset, inset)
		testing.expect_value(t, viewport.TopLeftY, f32(inset))
		testing.expect_value(t, viewport.Width, f32(1280))
		testing.expect_value(t, viewport.Height, f32(720))
	}
	// Very small/minimized client sizes cannot underflow the remaining height.
	for dimensions in ([4][3]u32{{32, 16, 42}, {0, 0, 42}, {480, 900, 42}, {1920, 762, 42}}) {
		viewport := video_viewport(dimensions[0], dimensions[1], dimensions[2])
		testing.expect(t, viewport.TopLeftX >= 0 && viewport.TopLeftY >= f32(min(dimensions[1], dimensions[2])))
		testing.expect(t, viewport.Width >= 0 && viewport.Height >= 0)
		testing.expect(t, viewport.TopLeftX+viewport.Width <= f32(dimensions[0])+0.001)
		testing.expect(t, viewport.TopLeftY+viewport.Height <= f32(dimensions[1])+0.001)
		testing.expect(t, abs(viewport.Width*9-viewport.Height*16) < 0.01)
	}
}

Test_Renderer_Swap_Chain :: struct {
	using vtable: ^dxgi.ISwapChain3_VTable,
	present_result: win32.HRESULT,
	present_count: int,
	present_interval: u32,
	present_flags: dxgi.PRESENT,
	resize_count: int,
	resize_width, resize_height: u32,
	resize_flags: dxgi.SWAP_CHAIN,
}

test_renderer_present :: proc "system" (this: ^dxgi.ISwapChain, interval: u32, flags: dxgi.PRESENT) -> win32.HRESULT {
	swap_chain := cast(^Test_Renderer_Swap_Chain)this
	swap_chain.present_count += 1
	swap_chain.present_interval = interval
	swap_chain.present_flags = flags
	return swap_chain.present_result
}

test_renderer_resize_buffers :: proc "system" (this: ^dxgi.ISwapChain, count, width, height: u32, format: dxgi.FORMAT, flags: dxgi.SWAP_CHAIN) -> win32.HRESULT {
	swap_chain := cast(^Test_Renderer_Swap_Chain)this
	swap_chain.resize_count += 1
	swap_chain.resize_width, swap_chain.resize_height = width, height
	swap_chain.resize_flags = flags
	return win32.HRESULT(win32.S_OK)
}

test_renderer_window :: proc(t: ^testing.T) -> win32.HWND {
	// Each test owns a real HWND on its own thread, without app/global state.
	hwnd := win32.CreateWindowExW(
		win32.WS_EX_TOOLWINDOW | win32.WS_EX_NOACTIVATE,
		cstring16("STATIC"), cstring16("ELGA renderer regression"),
		win32.WS_POPUP | win32.WS_VISIBLE, -32000, -32000, 64, 64,
		nil, nil, nil, nil,
	)
	testing.expect(t, hwnd != nil)
	return hwnd
}

test_renderer_message_pending :: proc(hwnd: win32.HWND, kind: u32) -> bool {
	msg: win32.MSG
	return bool(win32.PeekMessageW(&msg, hwnd, kind, kind, win32.PM_NOREMOVE))
}

@(test)
renderer_redraw_coalesces_without_posted_frame_messages_test :: proc(t: ^testing.T) {
	hwnd := test_renderer_window(t)
	if hwnd == nil do return
	defer win32.DestroyWindow(hwnd)
	r := Renderer{hwnd = hwnd}
	win32.ValidateRect(hwnd, nil)
	for _ in 0..<1000 do renderer_request_redraw(&r)
	testing.expect(t, bool(win32.GetUpdateRect(hwnd, nil, false)))
	testing.expect(t, test_renderer_message_pending(hwnd, win32.WM_PAINT))
	// The old WM_APP+1 frame notification could keep hardware input queued.
	testing.expect(t, !test_renderer_message_pending(hwnd, win32.WM_APP+1))
	win32.ValidateRect(hwnd, nil)
	testing.expect(t, !test_renderer_message_pending(hwnd, win32.WM_PAINT))
	testing.expect(t, !test_renderer_message_pending(hwnd, win32.WM_APP+1))
	// A frame arriving after paint validation must create the next paint.
	renderer_request_redraw(&r)
	testing.expect(t, bool(win32.GetUpdateRect(hwnd, nil, false)))
}

@(test)
renderer_present_is_nonblocking_and_only_accepts_success_test :: proc(t: ^testing.T) {
	vtable := dxgi.ISwapChain3_VTable{Present = test_renderer_present}
	swap_chain := Test_Renderer_Swap_Chain{vtable = &vtable}
	r := Renderer{swap_chain = cast(^dxgi.ISwapChain3)&swap_chain}
	for tearing in ([2]bool{false, true}) {
		r.allow_tearing = tearing
		for result in ([4]win32.HRESULT{
			win32.HRESULT(win32.S_OK), dxgi.ERROR_WAS_STILL_DRAWING,
			dxgi.STATUS_OCCLUDED, dxgi.ERROR_DEVICE_REMOVED,
		}) {
			swap_chain.present_result = result
			testing.expect_value(t, renderer_present(&r), result == win32.HRESULT(win32.S_OK))
			testing.expect_value(t, swap_chain.present_interval, u32(0))
			expected := dxgi.PRESENT{.DO_NOT_WAIT}
			if tearing do expected += {.ALLOW_TEARING}
			testing.expect_value(t, swap_chain.present_flags, expected)
		}
	}
	testing.expect_value(t, swap_chain.present_count, 8)
}

@(test)
renderer_retry_waits_for_timer_and_stops_after_success_test :: proc(t: ^testing.T) {
	hwnd := test_renderer_window(t)
	if hwnd == nil do return
	defer win32.DestroyWindow(hwnd)
	vtable := dxgi.ISwapChain3_VTable{Present = test_renderer_present}
	swap_chain := Test_Renderer_Swap_Chain{vtable = &vtable, present_result = dxgi.ERROR_WAS_STILL_DRAWING}
	r := Renderer{hwnd = hwnd, ready = true, swap_chain = cast(^dxgi.ISwapChain3)&swap_chain}
	defer renderer_cancel_redraw_retry(&r)
	win32.ValidateRect(hwnd, nil)
	for _ in 0..<100 do testing.expect(t, !renderer_present(&r))
	testing.expect(t, r.redraw_retry_pending)
	// A failed present must not immediately invalidate itself into a paint loop.
	testing.expect(t, !bool(win32.GetUpdateRect(hwnd, nil, false)))
	testing.expect(t, !test_renderer_message_pending(hwnd, win32.WM_APP+1))
	deadline := time.now()
	msg: win32.MSG
	for !bool(win32.PeekMessageW(&msg, hwnd, win32.WM_TIMER, win32.WM_TIMER, win32.PM_REMOVE)) {
		if time.since(deadline) > time.Second {
			testing.expect(t, false, "The renderer retry timer did not fire")
			return
		}
		time.sleep(time.Millisecond)
	}
	testing.expect_value(t, msg.wParam, win32.WPARAM(REDRAW_RETRY_TIMER))
	// Exercise the operations used by WM_TIMER with this test's local renderer.
	renderer_cancel_redraw_retry(&r)
	renderer_request_redraw(&r)
	testing.expect(t, !r.redraw_retry_pending)
	testing.expect(t, bool(win32.GetUpdateRect(hwnd, nil, false)))
	win32.ValidateRect(hwnd, nil)
	time.sleep(25*time.Millisecond)
	testing.expect(t, !test_renderer_message_pending(hwnd, win32.WM_TIMER))
	testing.expect(t, !test_renderer_message_pending(hwnd, win32.WM_PAINT))
	// Occlusion also needs another attempt when capture has stopped changing.
	swap_chain.present_result = dxgi.STATUS_OCCLUDED
	testing.expect(t, !renderer_present(&r))
	testing.expect(t, r.redraw_retry_pending)
	testing.expect(t, !bool(win32.GetUpdateRect(hwnd, nil, false)))
	swap_chain.present_result = win32.HRESULT(win32.S_OK)
	testing.expect(t, renderer_present(&r))
	testing.expect(t, !r.redraw_retry_pending)
	time.sleep(110*time.Millisecond)
	testing.expect(t, !test_renderer_message_pending(hwnd, win32.WM_TIMER))
	// Minimized and uninitialized renderers may not keep retry timers alive.
	r.capture_suspended = true
	renderer_retry_redraw(&r)
	testing.expect(t, !r.redraw_retry_pending)
	r.capture_suspended = false
	r.ready = false
	renderer_retry_redraw(&r)
	testing.expect(t, !r.redraw_retry_pending)
}

@(test)
renderer_resize_requests_coalesce_and_minimize_discards_stale_size_test :: proc(t: ^testing.T) {
	hwnd := test_renderer_window(t)
	if hwnd == nil do return
	defer win32.DestroyWindow(hwnd)
	vtable := dxgi.ISwapChain3_VTable{ResizeBuffers = test_renderer_resize_buffers}
	swap_chain := Test_Renderer_Swap_Chain{vtable = &vtable}
	r := Renderer{
		hwnd = hwnd, ready = true, width = 1280, height = 720, allow_tearing = true,
		resource_width = 1920, resource_height = 1080,
		swap_chain = cast(^dxgi.ISwapChain3)&swap_chain,
	}
	defer renderer_cancel_redraw_retry(&r)
	for width in 640..<1640 do renderer_request_resize(&r, u32(width), 900)
	testing.expect_value(t, r.pending_width, u32(1639))
	testing.expect_value(t, r.pending_height, u32(900))
	testing.expect_value(t, r.width, u32(1280))
	testing.expect_value(t, r.height, u32(720))
	testing.expect_value(t, swap_chain.resize_count, 0)
	renderer_request_resize(&r, 0, 0)
	testing.expect_value(t, r.pending_width, u32(1639))
	renderer_retry_redraw(&r)
	testing.expect(t, r.redraw_retry_pending)
	renderer_suspend_capture(&r)
	testing.expect_value(t, r.pending_width, u32(0))
	testing.expect_value(t, r.pending_height, u32(0))
	testing.expect(t, !r.redraw_retry_pending)
	testing.expect(t, r.capture_suspended)
	testing.expect_value(t, r.suspended_resource_width, u32(1920))
	testing.expect_value(t, r.suspended_resource_height, u32(1080))
	testing.expect_value(t, swap_chain.resize_count, 1)
	testing.expect_value(t, swap_chain.resize_width, u32(1))
	testing.expect_value(t, swap_chain.resize_height, u32(1))
	testing.expect_value(t, swap_chain.resize_flags, dxgi.SWAP_CHAIN{.ALLOW_TEARING})
	// A previously queued paint while minimized must neither resize nor resume.
	renderer_draw(&r)
	testing.expect(t, r.capture_suspended)
	testing.expect(t, !r.drawing)
	testing.expect_value(t, swap_chain.resize_count, 1)
	renderer_suspend_capture(&r)
	testing.expect_value(t, swap_chain.resize_count, 1)
	// Restore followed by minimize before paint must cancel the queued restore.
	renderer_request_resize(&r, 1280, 720)
	renderer_suspend_capture(&r)
	testing.expect_value(t, r.pending_width, u32(0))
	testing.expect_value(t, r.pending_height, u32(0))
	testing.expect(t, r.capture_suspended)
	testing.expect_value(t, swap_chain.resize_count, 1)
}

@(test)
renderer_nested_draw_defers_work_without_losing_pending_size_test :: proc(t: ^testing.T) {
	hwnd := test_renderer_window(t)
	if hwnd == nil do return
	defer win32.DestroyWindow(hwnd)
	r := Renderer{hwnd = hwnd, ready = true, drawing = true, pending_width = 1920, pending_height = 1080}
	defer renderer_cancel_redraw_retry(&r)
	// No D3D pointers are installed: recursive rendering must return before use.
	renderer_draw(&r)
	testing.expect(t, r.drawing)
	testing.expect(t, r.redraw_retry_pending)
	testing.expect_value(t, r.pending_width, u32(1920))
	testing.expect_value(t, r.pending_height, u32(1080))
}

@(test)
renderer_minimize_during_draw_waits_until_draw_unwinds_test :: proc(t: ^testing.T) {
	vtable := dxgi.ISwapChain3_VTable{ResizeBuffers = test_renderer_resize_buffers}
	swap_chain := Test_Renderer_Swap_Chain{vtable = &vtable}
	r := Renderer{
		ready = true, drawing = true, pending_width = 1920, pending_height = 1080,
		swap_chain = cast(^dxgi.ISwapChain3)&swap_chain,
	}
	renderer_suspend_capture(&r)
	testing.expect(t, r.suspend_requested)
	testing.expect(t, !r.capture_suspended)
	testing.expect_value(t, swap_chain.resize_count, 0)
	testing.expect_value(t, r.pending_width, u32(0))
	testing.expect_value(t, r.pending_height, u32(0))
	// An empty draw takes the usual defer path without using the global arena.
	r.drawing = false
	renderer_draw(&r)
	testing.expect(t, !r.drawing)
	testing.expect(t, !r.suspend_requested)
	testing.expect(t, r.capture_suspended)
	testing.expect_value(t, swap_chain.resize_count, 1)

	// A restore delivered during the same outer draw supersedes the minimize.
	r = {ready = true, drawing = true}
	renderer_suspend_capture(&r)
	testing.expect(t, r.suspend_requested)
	renderer_request_resize(&r, 1280, 720)
	testing.expect(t, !r.suspend_requested)
	testing.expect_value(t, r.pending_width, u32(1280))
	testing.expect_value(t, r.pending_height, u32(720))

	// Minimize may also reenter ResizeBuffers during a minimized-window restore.
	// Remember it even though capture is still suspended at that instant.
	r = {ready = true, drawing = true, capture_suspended = true, pending_width = 1280, pending_height = 720}
	renderer_suspend_capture(&r)
	testing.expect(t, r.suspend_requested)
	testing.expect_value(t, r.pending_width, u32(0))
	testing.expect_value(t, r.pending_height, u32(0))
	r.drawing = false
	renderer_draw(&r)
	testing.expect(t, !r.suspend_requested)
	testing.expect(t, r.capture_suspended)
}
