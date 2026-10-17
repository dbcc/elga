package main

import "core:sync"
import "core:testing"
import "core:thread"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import imgui "../vendor/odin-imgui"
import imgui_dx11 "../vendor/odin-imgui/imgui_impl_dx11"

Test_Removed_Device :: struct {
	using vtable: ^d3d11.IDevice_VTable,
	reason: win32.HRESULT,
}

test_device_removed_reason :: proc "system" (this: ^d3d11.IDevice) -> win32.HRESULT {
	return (cast(^Test_Removed_Device)this).reason
}

test_device_lost_resize_buffers :: proc "system" (this: ^dxgi.ISwapChain, count, width, height: u32, format: dxgi.FORMAT, flags: dxgi.SWAP_CHAIN) -> win32.HRESULT {
	swap_chain := cast(^Test_Renderer_Swap_Chain)this
	swap_chain.resize_count += 1
	return dxgi.ERROR_DEVICE_REMOVED
}

@(test)
device_recovery_classifies_device_errors_test :: proc(t: ^testing.T) {
	for hr in ([4]win32.HRESULT{dxgi.ERROR_DEVICE_REMOVED, dxgi.ERROR_DEVICE_RESET, dxgi.ERROR_DEVICE_HUNG, dxgi.ERROR_DRIVER_INTERNAL_ERROR}) {
		testing.expect(t, renderer_device_lost_error(hr))
	}
	for hr in ([4]win32.HRESULT{win32.HRESULT(win32.S_OK), dxgi.ERROR_WAS_STILL_DRAWING, dxgi.STATUS_OCCLUDED, RENDERER_RESOURCES_FAILED}) {
		testing.expect(t, !renderer_device_lost_error(hr))
	}
}

@(test)
device_recovery_present_and_resize_stop_gpu_use_test :: proc(t: ^testing.T) {
	vtable := dxgi.ISwapChain3_VTable{Present = test_renderer_present, ResizeBuffers = test_device_lost_resize_buffers}
	swap_chain := Test_Renderer_Swap_Chain{vtable = &vtable, present_result = dxgi.ERROR_WAS_STILL_DRAWING}
	r := Renderer{ready = true, width = 1280, height = 720, swap_chain = cast(^dxgi.ISwapChain3)&swap_chain}
	// A busy queue is not device loss.
	testing.expect(t, !renderer_present(&r))
	testing.expect(t, r.ready && !r.device_lost)
	swap_chain.present_result = dxgi.ERROR_DEVICE_REMOVED
	testing.expect(t, !renderer_present(&r))
	testing.expect(t, !r.ready && r.device_lost)
	testing.expect_value(t, r.device_lost_reason, dxgi.ERROR_DEVICE_REMOVED)
	// Later failures keep the first reason.
	swap_chain.present_result = dxgi.ERROR_DEVICE_RESET
	testing.expect(t, !renderer_present(&r))
	testing.expect_value(t, r.device_lost_reason, dxgi.ERROR_DEVICE_REMOVED)

	// A lost device must not try to recreate back buffers after ResizeBuffers.
	// The fake swap chain has no GetBuffer, so attempting it would crash.
	r = {ready = true, width = 1280, height = 720, swap_chain = cast(^dxgi.ISwapChain3)&swap_chain}
	renderer_resize(&r, 1920, 1080)
	testing.expect_value(t, swap_chain.resize_count, 1)
	testing.expect(t, !r.ready && r.device_lost)
	testing.expect_value(t, r.width, u32(1280))
}

@(test)
device_recovery_polls_both_devices_and_failed_resources_test :: proc(t: ^testing.T) {
	vtable := d3d11.IDevice_VTable{GetDeviceRemovedReason = test_device_removed_reason}
	render := Test_Removed_Device{vtable = &vtable, reason = win32.HRESULT(win32.S_OK)}
	capture := Test_Removed_Device{vtable = &vtable, reason = win32.HRESULT(win32.S_OK)}
	r := Renderer{
		ready = true,
		device_11 = cast(^d3d11.IDevice)&render,
		capture_device_11 = cast(^d3d11.IDevice)&capture,
	}
	now := time.now()
	testing.expect(t, !renderer_device_recovery_due(&r, now))
	testing.expect(t, r.ready && !r.device_lost)
	// Present never reports a capture-device loss; the UI tick poll must.
	capture.reason = dxgi.ERROR_DEVICE_HUNG
	r.drawing = true
	testing.expect(t, !renderer_device_recovery_due(&r, now))
	testing.expect(t, !r.device_lost)
	r.drawing = false
	testing.expect(t, renderer_device_recovery_due(&r, now))
	testing.expect(t, r.device_lost && !r.ready)
	testing.expect_value(t, r.device_lost_reason, dxgi.ERROR_DEVICE_HUNG)

	// A renderer that could not restore its resources is rebuilt the same way.
	capture.reason = win32.HRESULT(win32.S_OK)
	r = {device_11 = cast(^d3d11.IDevice)&render, capture_device_11 = cast(^d3d11.IDevice)&capture}
	testing.expect(t, renderer_device_recovery_due(&r, now))
	testing.expect_value(t, r.device_lost_reason, RENDERER_RESOURCES_FAILED)
	// Without devices there is nothing to recover: startup and tests stay idle.
	r = {}
	testing.expect(t, !renderer_device_recovery_due(&r, now))
	testing.expect(t, !r.device_lost)
}

@(test)
device_recovery_stops_capture_async_and_backs_off_test :: proc(t: ^testing.T) {
	hwnd := test_renderer_window(t)
	if hwnd == nil do return
	defer win32.DestroyWindow(hwnd)
	vt := dxgi.ISwapChain3_VTable{ResizeBuffers = test_renderer_resize_buffers}
	swap_chain := Test_Renderer_Swap_Chain{vtable = &vt}
	r := Renderer{
		hwnd = hwnd, ready = true, capture_running = true, capture_generation = 3,
		capture_format = .YUY2, requested_width = 2560, requested_height = 1440,
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

	renderer_mark_device_lost(&r, RENDERER_RESOURCES_FAILED)
	now := time.now()
	// Source shutdown blocks in the driver; the window thread must return.
	testing.expect(t, !renderer_device_recovery_due(&r, now))
	testing.expect_value(t, win32.WaitForSingleObject(fixture.stop_entered, 1000), win32.WAIT_OBJECT_0)
	testing.expect(t, r.reconnect_thread != nil)
	testing.expect_value(t, sync.atomic_load(&r.capture_generation), u32(4))
	testing.expect(t, !renderer_device_recovery_due(&r, now))
	testing.expect(t, !renderer_update_reconnect(&r))
	win32.SetEvent(fixture.allow_stop)
	deadline := time.now()
	for sync.atomic_load_explicit(&r.reconnect_done, .Acquire) == 0 {
		if time.since(deadline) > time.Second {
			testing.expect(t, false, "Capture shutdown did not finish")
			return
		}
		time.sleep(time.Millisecond)
	}
	// Joining the worker must not restart capture or touch the lost swap chain.
	testing.expect(t, renderer_update_reconnect(&r))
	testing.expect(t, r.reconnect_thread == nil && r.capture_thread == nil)
	testing.expect(t, !r.ready && r.device_lost && !r.reconnect_error)
	testing.expect_value(t, swap_chain.resize_count, 0)
	testing.expect_value(t, r.capture_format, Capture_Format.YUY2)
	testing.expect_value(t, r.requested_width, u32(2560))
	testing.expect(t, renderer_device_recovery_due(&r, now))

	// Minimized windows wait so the swap chain is not rebuilt at 1x1.
	win32.ShowWindow(hwnd, win32.SW_SHOWMINNOACTIVE)
	if testing.expect(t, bool(win32.IsIconic(hwnd))) {
		testing.expect(t, !renderer_device_recovery_due(&r, now))
	}
	win32.ShowWindow(hwnd, win32.SW_SHOWNOACTIVATE)
	testing.expect(t, renderer_device_recovery_due(&r, now))

	// Failed attempts back off by a second each, up to the maximum delay.
	for attempt in 1..=7 {
		renderer_schedule_device_retry(&r, now)
		delay := min(time.Duration(attempt)*time.Second, DEVICE_RECOVERY_MAX_DELAY)
		testing.expect_value(t, r.device_retry_count, u32(attempt))
		testing.expect(t, !renderer_device_recovery_due(&r, time.time_add(now, delay-time.Millisecond)))
		testing.expect(t, renderer_device_recovery_due(&r, time.time_add(now, delay)))
	}
}

// Opt in on a Windows machine with a D3D11 GPU. No capture card is needed.
when #config(ELGA_GPU_TESTS, false) {
	@(test)
	device_recovery_gpu_rebuild_test :: proc(t: ^testing.T) {
		device_recovery_gpu_rebuild(t)
	}
}

// Builds the devices, swap chain, video resources and ImGui backend, releases
// them as recovery does, and builds them again on the same window.
device_recovery_gpu_rebuild :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_imgui_mutex)
	defer sync.mutex_unlock(&test_imgui_mutex)
	hwnd := test_renderer_window(t)
	if hwnd == nil do return
	defer win32.DestroyWindow(hwnd)
	r := Renderer{hwnd = hwnd}
	ui: ImGui_State
	previous_context := imgui.GetCurrentContext()
	defer {
		imgui_ui_destroy(&ui)
		renderer_release_device_objects(&r)
		imgui.SetCurrentContext(previous_context)
	}
	for round in 0..<3 {
		if !testing.expect(t, renderer_create_device_objects(&r, 64, 36), "Device objects could not be created") do return
		attached := imgui_ui_init(&ui, &r) if round == 0 else imgui_ui_attach_device(&ui, &r)
		if !testing.expect(t, attached, "ImGui backend could not attach") do return
		if !testing.expect(t, video_resources_create(&r, .NV12, 32, 18)) do return

		// Solid ImGui shapes sample the font atlas's white texel, so a white
		// result shows the backend recreated its atlas texture on this device.
		io := imgui.GetIO()
		io.DisplaySize = {64, 36}
		io.DeltaTime = 1.0/60.0
		imgui_dx11.NewFrame()
		imgui.NewFrame()
		imgui.DrawList_AddRectFilled(imgui.GetForegroundDrawList(), {0, 0}, {64, 36}, 0xffffffff)
		imgui.Render()
		clear := [4]f32{0, 0, 0, 1}
		r.context_11.ClearRenderTargetView(r.context_11, r.target, &clear)
		targets := [1]^d3d11.IRenderTargetView{r.target}
		r.context_11.OMSetRenderTargets(r.context_11, 1, &targets[0], nil)
		imgui_ui_render(&ui, imgui.GetDrawData())

		staging: ^d3d11.ITexture2D
		desc := d3d11.TEXTURE2D_DESC{
			Width = 64, Height = 36, MipLevels = 1, ArraySize = 1,
			Format = .R8G8B8A8_UNORM, SampleDesc = {Count = 1},
			Usage = .STAGING, CPUAccessFlags = {.READ},
		}
		if !testing.expect(t, !failed(r.device_11.CreateTexture2D(r.device_11, &desc, nil, &staging))) do return
		r.context_11.CopyResource(r.context_11, cast(^d3d11.IResource)staging, cast(^d3d11.IResource)r.back_buffer)
		mapped: d3d11.MAPPED_SUBRESOURCE
		if testing.expect(t, !failed(r.context_11.Map(r.context_11, cast(^d3d11.IResource)staging, 0, .READ, {}, &mapped))) {
			pixel := (cast([^]u8)mapped.pData)[18*int(mapped.RowPitch)+32*4:][:3]
			testing.expectf(t, pixel[0] == 255 && pixel[1] == 255 && pixel[2] == 255, "round %d: ImGui drew %v instead of white", round, pixel)
			r.context_11.Unmap(r.context_11, cast(^d3d11.IResource)staging, 0)
		}
		com_release(staging)

		imgui_ui_release_device(&ui)
		renderer_release_device_objects(&r)
		testing.expect(t, !ui.ready && ui.ctx != nil)
		testing.expect(t, r.device_11 == nil && r.context_11 == nil && r.capture_device_11 == nil && r.capture_context_11 == nil)
		testing.expect(t, r.swap_chain == nil && r.back_buffer == nil && r.target == nil)
		testing.expect(t, r.video_device == nil && r.video_context == nil && r.video_context_1 == nil)
		testing.expect(t, r.vertex_shader == nil && r.native_pixel_shader == nil && r.flipped_pixel_shader == nil)
		testing.expect(t, r.sampler == nil && r.rasterizer == nil)
		testing.expect(t, r.capture_texture == nil && r.processed_texture == nil && r.video_texture == nil && r.rgb_view == nil)
		testing.expect(t, r.capture_mutex == nil && r.render_mutex == nil && r.video_processor == nil)
	}
}
