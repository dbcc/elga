package main

import "core:fmt"
import "core:mem"
import win32 "core:sys/windows"
import "core:thread"
import "core:sync"
import "core:time"
import d3d11 "vendor:directx/d3d11"
import d3dc "vendor:directx/d3d_compiler"
import dxgi "vendor:directx/dxgi"

SWAP_CHAIN_BUFFER_COUNT :: 2
MAX_CAPTURE_MODES :: 1024
CAPTURE_AUTO_WIDTH  :: 3840
CAPTURE_AUTO_HEIGHT :: 2160

// The user's capture selection plus the size of the GPU resources built for it.
// A zero requested size means Auto (highest resolution).
Capture_Config :: struct {
	capture_format:   Capture_Format,
	format_auto:      bool,
	requested_width:  u32,
	requested_height: u32,
	resource_width:   u32,
	resource_height:  u32,
}

Renderer :: struct {
	enhancements: Video_Enhancements,
	ready:          bool,
	hwnd:           win32.HWND,
	width:          u32,
	height:         u32,
	pending_width:  u32,
	pending_height: u32,
	drawing:        bool,
	suspend_requested: bool,
	redraw_retry_pending: bool,
	health: Capture_Health,
	reconnect_thread: ^thread.Thread,
	reconnect_done: u32,
	reconnect_error: bool,
	edid_status: u32,
	edid_error: u32,
	edid_mode: u32,
	edid_mode_known: u32,
	edid_request_kind: u32,
	edid_request_id: u32,
	edid_request_generation: u32,
	edid_requested_mode: u32,
	edid_operation_active: u32,
	edid_result_pending: u32,
	edid_result_id: u32,
	edid_result_generation: u32,
	edid_result_disposition: u32,
	edid_restore_pending: u32,
	edid_notice: u32,
	edid_verification_required: u32,
	device_11:      ^d3d11.IDevice,
	context_11:     ^d3d11.IDeviceContext,
	capture_device_11:  ^d3d11.IDevice,
	capture_context_11: ^d3d11.IDeviceContext,
	swap_chain:     ^dxgi.ISwapChain3,
	back_buffer:    ^d3d11.ITexture2D,
	target:         ^d3d11.IRenderTargetView,
	allow_tearing:  bool,
	video_texture:  ^d3d11.ITexture2D,
	capture_texture:^d3d11.ITexture2D,
	processed_texture: ^d3d11.ITexture2D,
	capture_mutex:  ^dxgi.IKeyedMutex,
	render_mutex:   ^dxgi.IKeyedMutex,
	rgb_view:       ^d3d11.IShaderResourceView,
	vertex_shader:  ^d3d11.IVertexShader,
	native_pixel_shader: ^d3d11.IPixelShader,
	flipped_pixel_shader: ^d3d11.IPixelShader,
	video_device:   ^d3d11.IVideoDevice,
	video_context:  ^d3d11.IVideoContext,
	video_context_1: ^ID3D11VideoContext1,
	video_enumerator: ^d3d11.IVideoProcessorEnumerator,
	video_processor: ^d3d11.IVideoProcessor,
	video_input_view: ^d3d11.IVideoProcessorInputView,
	video_output_view: ^d3d11.IVideoProcessorOutputView,
	sampler:        ^d3d11.ISamplerState,
	rasterizer:     ^d3d11.IRasterizerState,
	letterboxed:    bool,
	video_top_inset: u32,
	video_sequence: u64,
	video_timestamp, video_arrival: i64,
	video_vertical_flip: u32,
	capture_running: bool,
	capture_ready:   u32,
	capture_refresh: u32,
	capture_thread:  ^thread.Thread,
	capture_event:   win32.HANDLE,
	capture_generation: u32,
	capture_suspended: bool,
	suspended_resource_width: u32,
	suspended_resource_height: u32,
	// Negotiated by the capture thread before capture_ready; zero until then.
	mode:            Capture_Mode,
	using config:    Capture_Config,
	capture_formats: u32,
	capture_mode_indices: [MAX_CAPTURE_MODES]u16,
	capture_mode_count: u32,
	source_modes:    [MAX_CAPTURE_MODES]Capture_Mode,
	source_mode_count: u32,
	startup_auto_resolved: bool,
	// The last configuration that delivered frames, restored when a newly
	// selected mode fails to negotiate.
	last_working:       Capture_Config,
	last_working_valid: bool,
	display_fps:        f64,
	fps_window_start:   time.Time,
	fps_window_frames:  u32,
	last_presented_seq: u64,
	last_video_present: time.Time,
}

renderer_request_redraw :: proc(r: ^Renderer) {
	if r == nil || r.hwnd == nil do return
	// Posted frame messages outrank hardware input and can monopolize the UI
	// thread under capture load. Invalidations coalesce and yield to input,
	// including inside Windows' modal move/resize loop.
	win32.InvalidateRect(r.hwnd, nil, false)
}

// Called only on the window thread. Retry without keeping WM_PAINT permanently
// pending or requiring another capture (the last shared frame may be busy).
renderer_retry_redraw :: proc(r: ^Renderer, delay_ms: u32 = win32.USER_TIMER_MINIMUM) {
	if r.hwnd == nil || !r.ready || r.capture_suspended || r.redraw_retry_pending do return
	r.redraw_retry_pending = win32.SetTimer(r.hwnd, REDRAW_RETRY_TIMER, delay_ms, nil) != 0
}

renderer_cancel_redraw_retry :: proc(r: ^Renderer) {
	if !r.redraw_retry_pending do return
	win32.KillTimer(r.hwnd, REDRAW_RETRY_TIMER)
	r.redraw_retry_pending = false
}

renderer_request_ui_redraw :: proc(r: ^Renderer) {
	if r == nil || !r.ready || r.capture_suspended do return
	// Let incoming frames drive the UI, but keep controls usable if HDMI stalls.
	if r.last_video_present != {} && time.since(r.last_video_present) < 100*time.Millisecond do return
	renderer_request_redraw(r)
}

renderer_init :: proc(r: ^Renderer, hwnd: win32.HWND, width, height: u32) -> (success: bool) {
	defer {
		if !success do renderer_destroy(r)
	}
	r.hwnd = hwnd
	r.width = max(width, 1)
	r.height = max(height, 1)
	r.capture_format = .NV12
	r.format_auto = true
	sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Unavailable), .Relaxed)
	sync.atomic_store_explicit(&r.capture_formats, u32(1)<<u32(Capture_Format.NV12), .Relaxed)

	factory: ^dxgi.IFactory4
	if !check(dxgi.CreateDXGIFactory2({}, dxgi.IFactory4_UUID, cast(^rawptr)&factory), "CreateDXGIFactory2") do return false
	defer com_release(factory)
	factory_5: ^dxgi.IFactory5
	if !failed(factory.QueryInterface(factory, dxgi.IFactory5_UUID, cast(^rawptr)&factory_5)) {
		tearing_supported: win32.BOOL
		if !failed(factory_5.CheckFeatureSupport(factory_5, .PRESENT_ALLOW_TEARING, &tearing_supported, size_of(tearing_supported))) {
			r.allow_tearing = bool(tearing_supported)
		}
		com_release(factory_5)
	}

	feature_levels := [1]d3d11.FEATURE_LEVEL{._11_0}
	if !check(d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, &feature_levels[0], 1, d3d11.SDK_VERSION, &r.device_11, nil, &r.context_11), "Render D3D11CreateDevice") do return false
	// Shared capture and enhancement textures must stay on the render adapter.
	dxgi_device: ^dxgi.IDevice
	if !check(r.device_11.QueryInterface(r.device_11, dxgi.IDevice_UUID, cast(^rawptr)&dxgi_device), "Render IDXGIDevice") do return false
	defer com_release(dxgi_device)
	adapter: ^dxgi.IAdapter
	if !check(dxgi_device.GetAdapter(dxgi_device, &adapter), "Render adapter") do return false
	defer com_release(adapter)
	if !check(d3d11.CreateDevice(adapter, .UNKNOWN, nil, {.BGRA_SUPPORT, .VIDEO_SUPPORT}, &feature_levels[0], 1, d3d11.SDK_VERSION, &r.capture_device_11, nil, &r.capture_context_11), "Capture D3D11CreateDevice") do return false
	// Media Foundation and the capture callback share the capture context.
	multithread: ^ID3D10Multithread
	if !check(r.capture_device_11.QueryInterface(r.capture_device_11, ID3D10Multithread_UUID, cast(^rawptr)&multithread), "Capture multithread protection") do return false
	multithread.SetMultithreadProtected(multithread, true)
	com_release(multithread)
	if !check(r.capture_device_11.QueryInterface(r.capture_device_11, d3d11.IVideoDevice_UUID, cast(^rawptr)&r.video_device), "IVideoDevice") do return false
	if !check(r.capture_context_11.QueryInterface(r.capture_context_11, d3d11.IVideoContext_UUID, cast(^rawptr)&r.video_context), "IVideoContext") do return false
	// Optional on older systems; the legacy color-space path remains available.
	r.capture_context_11.QueryInterface(r.capture_context_11, ID3D11VideoContext1_UUID, cast(^rawptr)&r.video_context_1)

	swap_desc := dxgi.SWAP_CHAIN_DESC1 {
		Width       = r.width,
		Height      = r.height,
		Format      = .R8G8B8A8_UNORM,
		SampleDesc  = {Count = 1},
		BufferUsage = {.RENDER_TARGET_OUTPUT},
		BufferCount = SWAP_CHAIN_BUFFER_COUNT,
		Scaling     = .STRETCH,
		SwapEffect  = .FLIP_DISCARD,
		AlphaMode   = .UNSPECIFIED,
		Flags       = renderer_swap_chain_flags(r),
	}
	swap1: ^dxgi.ISwapChain1
	if !check(factory.CreateSwapChainForHwnd(factory, cast(^dxgi.IUnknown)r.device_11, hwnd, &swap_desc, nil, nil, &swap1), "CreateSwapChainForHwnd") do return false
	defer com_release(swap1)
	if !check(swap1.QueryInterface(swap1, dxgi.ISwapChain3_UUID, cast(^rawptr)&r.swap_chain), "IDXGISwapChain3") do return false
	factory.MakeWindowAssociation(factory, hwnd, {.NO_ALT_ENTER})
	r.fps_window_start = time.now()

	if !renderer_create_back_buffers(r) do return false
	if !video_pipeline_init(r) do return false
	if !capture_start(r) do return false
	r.ready = true
	return true
}

renderer_swap_chain_flags :: proc(r: ^Renderer) -> dxgi.SWAP_CHAIN {
	return {.ALLOW_TEARING} if r.allow_tearing else {}
}

renderer_resize_swap_chain :: proc(r: ^Renderer, width, height: u32) -> win32.HRESULT {
	// ResizeBuffers must preserve ALLOW_TEARING from swap-chain creation.
	return r.swap_chain.ResizeBuffers(r.swap_chain, SWAP_CHAIN_BUFFER_COUNT, width, height, .R8G8B8A8_UNORM, renderer_swap_chain_flags(r))
}

renderer_create_back_buffers :: proc(r: ^Renderer) -> bool {
	if !check(r.swap_chain.GetBuffer(r.swap_chain, 0, d3d11.ITexture2D_UUID, cast(^rawptr)&r.back_buffer), "Swap-chain buffer") do return false
	if !check(r.device_11.CreateRenderTargetView(r.device_11, cast(^d3d11.IResource)r.back_buffer, nil, &r.target), "Swap-chain render target") {
		renderer_release_back_buffers(r)
		return false
	}
	return true
}

renderer_draw :: proc(r: ^Renderer) {
	if !r.ready do return
	if r.drawing {
		renderer_retry_redraw(r)
		return
	}
	r.drawing = true
	defer {
		r.drawing = false
		if r.suspend_requested do renderer_suspend_capture(r)
	}
	if r.pending_width != 0 && r.pending_height != 0 {
		width, height := r.pending_width, r.pending_height
		r.pending_width, r.pending_height = 0, 0
		renderer_resize(r, width, height)
		if !r.suspend_requested && r.width == width && r.height == height do renderer_resume_capture(r)
	}
	if !r.ready || r.capture_suspended || r.width == 0 || r.height == 0 do return
	frame_allocator := mem.arena_allocator(&app.frame_arena)
	context.allocator = frame_allocator
	context.temp_allocator = frame_allocator
	defer mem.arena_free_all(&app.frame_arena)

	if r.target == nil do return
	video_top_inset := u32(0)
	if app.ui.ready && app.controls_visible {
		video_top_inset = u32(title_bar_height_for_dpi(win32.GetDpiForWindow(r.hwnd)))
	}
	if r.video_top_inset != video_top_inset {
		r.video_top_inset = video_top_inset
		video_pipeline_bind(r)
	}
	sequence := sync.atomic_load_explicit(&r.video_sequence, .Acquire)
	has_frame := sequence != 0 && r.reconnect_thread == nil && sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0
	presented_sequence: u64

	if !has_frame || r.letterboxed {
		clear := [4]f32{0, 0, 0, 1}
		r.context_11.ClearRenderTargetView(r.context_11, r.target, &clear)
	}
	if has_frame {
		// Keep the previous presentation on screen while capture owns the surface.
		presented_sequence = video_pipeline_draw(r, r.target)
		if presented_sequence == 0 {
			renderer_retry_redraw(r)
			return
		}
	}

	// Skip all ImGui work while the fullscreen title bar is hidden.
	if app.ui.ready && (app.controls_visible || app.ui.menu_open || screenshot_feedback_visible()) {
		draw_data := imgui_ui_new_frame(&app.ui, r)
		targets := [1]^d3d11.IRenderTargetView{r.target}
		r.context_11.OMSetRenderTargets(r.context_11, 1, &targets[0], nil)
		imgui_ui_render(&app.ui, draw_data)
	}

	if !renderer_present(r) do return
	now := time.now()
	enhanced_new := r.enhancements.cached.token != 0 && r.enhancements.cached.token != r.enhancements.presented_token
	if presented_sequence != 0 && (presented_sequence != r.last_presented_seq || enhanced_new) {
		r.last_presented_seq = presented_sequence
		r.last_video_present = now
		r.fps_window_frames += 1
		capture_health_mark_present(r)
		video_enhancements_presented(r)
	}
	elapsed := time.duration_seconds(time.diff(r.fps_window_start, now))
	if elapsed >= 0.5 {
		r.display_fps = f64(r.fps_window_frames) / elapsed
		r.fps_window_frames = 0
		r.fps_window_start = now
	}
}

renderer_present :: proc(r: ^Renderer) -> bool {
	// A zero sync interval alone can still sleep behind a full display queue.
	// Keep the window thread available for dragging when the compositor is busy.
	present_flags := dxgi.PRESENT{.DO_NOT_WAIT}
	if r.allow_tearing do present_flags += {.ALLOW_TEARING}
	hr := r.swap_chain.Present(r.swap_chain, 0, present_flags)
	switch hr {
	case win32.HRESULT(win32.S_OK):
		renderer_cancel_redraw_retry(r)
		return true
	case dxgi.ERROR_WAS_STILL_DRAWING:
		renderer_retry_redraw(r)
	case dxgi.STATUS_OCCLUDED:
		renderer_retry_redraw(r, 100)
	}
	return false
}

renderer_request_resize :: proc(r: ^Renderer, width, height: u32) {
	if !r.ready || width == 0 || height == 0 do return
	r.suspend_requested = false
	// Size messages can arrive faster than GPU buffers can be recreated. Apply
	// only the latest client size when the next paint gets its turn.
	r.pending_width, r.pending_height = width, height
	renderer_request_redraw(r)
}

renderer_resize :: proc(r: ^Renderer, width, height: u32) {
	if !r.ready || width == 0 || height == 0 || (r.width == width && r.height == height) do return
	renderer_release_back_buffers(r)
	if !check(renderer_resize_swap_chain(r, width, height), "ResizeBuffers") {
		renderer_restore_back_buffers(r)
		return
	}
	r.width = width
	r.height = height
	renderer_restore_back_buffers(r)
}

renderer_restore_back_buffers :: proc(r: ^Renderer) -> bool {
	if !renderer_create_back_buffers(r) {
		fmt.eprintln("Could not recreate swap-chain render targets")
		r.ready = false
		return false
	}
	video_pipeline_bind(r)
	return true
}

renderer_release_back_buffers :: proc(r: ^Renderer) {
	if r.context_11 != nil {
		r.context_11.OMSetRenderTargets(r.context_11, 0, nil, nil)
		r.context_11.ClearState(r.context_11)
	}
	com_clear(&r.target)
	com_clear(&r.back_buffer)
	if r.context_11 != nil do r.context_11.Flush(r.context_11)
}

renderer_destroy :: proc(r: ^Renderer) {
	if r == nil do return
	video_enhancements_destroy(r)
	renderer_cancel_redraw_retry(r)
	// The reconnect worker owns capture_stop until it finishes.
	if r.reconnect_thread != nil {
		thread.join(r.reconnect_thread)
		thread.destroy(r.reconnect_thread)
		r.reconnect_thread = nil
	}
	capture_stop(r)
	renderer_release_back_buffers(r)
	com_release(r.rasterizer)
	com_release(r.sampler)
	com_release(r.vertex_shader)
	com_release(r.native_pixel_shader)
	com_release(r.flipped_pixel_shader)
	video_resources_release(r)
	com_release(r.capture_context_11)
	com_release(r.capture_device_11)
	com_release(r.video_context_1)
	com_release(r.video_context)
	com_release(r.video_device)
	com_release(r.context_11)
	com_release(r.device_11)
	com_release(r.swap_chain)
	r^ = {}
}

video_pipeline_init :: proc(r: ^Renderer) -> bool {
	vs := compile_shader("VSMain", "vs_5_0")
	if vs == nil do return false
	defer com_release(vs)
	if !check(r.device_11.CreateVertexShader(r.device_11, vs.GetBufferPointer(vs), vs.GetBufferSize(vs), nil, &r.vertex_shader), "Video vertex shader") do return false
	if !create_pixel_shader(r, "PSNativeRGB", &r.native_pixel_shader) do return false
	if !create_pixel_shader(r, "PSNativeRGBFlipped", &r.flipped_pixel_shader) do return false

	sampler_desc := d3d11.SAMPLER_DESC{Filter = .MIN_MAG_LINEAR_MIP_POINT, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP, MaxLOD = 3.402823466e+38}
	if !check(r.device_11.CreateSamplerState(r.device_11, &sampler_desc, &r.sampler), "Video sampler") do return false
	raster_desc := d3d11.RASTERIZER_DESC{FillMode = .SOLID, CullMode = .NONE, DepthClipEnable = true}
	if !check(r.device_11.CreateRasterizerState(r.device_11, &raster_desc, &r.rasterizer), "Video rasterizer") do return false
	if !video_resources_create(r, r.capture_format, CAPTURE_AUTO_WIDTH, CAPTURE_AUTO_HEIGHT) do return false
	video_pipeline_bind(r)
	return true
}

create_pixel_shader :: proc(r: ^Renderer, entry: cstring, shader: ^^d3d11.IPixelShader) -> bool {
	code := compile_shader(entry, "ps_5_0")
	if code == nil do return false
	defer com_release(code)
	return check(r.device_11.CreatePixelShader(r.device_11, code.GetBufferPointer(code), code.GetBufferSize(code), nil, shader), string(entry))
}

// Builds the capture-side textures and the keyed-mutex-shared BGRA frame the
// render device presents. RGB24 arrives display-ready from Media Foundation, so
// it is copied straight into the shared frame and needs no video processor.
video_resources_create :: proc(r: ^Renderer, format: Capture_Format, width, height: u32) -> (success: bool) {
	defer {
		if !success do video_resources_release(r)
	}
	if format != .RGB24 {
		input_desc := d3d11.TEXTURE2D_DESC {
			Width      = width,
			Height     = height,
			MipLevels  = 1,
			ArraySize  = 1,
			Format     = capture_format_dxgi(format),
			SampleDesc = {Count = 1},
			Usage      = .DEFAULT,
			// BindFlags=0 is explicitly valid for a video-processor input view.
			BindFlags  = {},
		}
		if !check(r.capture_device_11.CreateTexture2D(r.capture_device_11, &input_desc, nil, &r.capture_texture), "Video input texture") do return false
	}
	output_desc := d3d11.TEXTURE2D_DESC {
		Width = width, Height = height, MipLevels = 1, ArraySize = 1,
		Format = .B8G8R8A8_UNORM, SampleDesc = {Count = 1}, Usage = .DEFAULT,
		BindFlags = {.RENDER_TARGET, .SHADER_RESOURCE}, MiscFlags = {.SHARED_KEYEDMUTEX, .SHARED_NTHANDLE},
	}
	if !check(r.capture_device_11.CreateTexture2D(r.capture_device_11, &output_desc, nil, &r.processed_texture), "Video output texture") do return false
	shared_resource: ^dxgi.IResource1
	if !check(r.processed_texture.QueryInterface(r.processed_texture, dxgi.IResource1_UUID, cast(^rawptr)&shared_resource), "Video output IDXGIResource1") do return false
	defer com_release(shared_resource)
	shared_handle: win32.HANDLE
	if !check(shared_resource.CreateSharedHandle(shared_resource, nil, {.READ, .WRITE}, nil, &shared_handle), "Video shared handle") do return false
	defer win32.CloseHandle(shared_handle)

	device_1: ^ID3D11Device1
	if !check(r.device_11.QueryInterface(r.device_11, ID3D11Device1_UUID, cast(^rawptr)&device_1), "Render ID3D11Device1") do return false
	defer com_release(device_1)
	if !check(device_1.OpenSharedResource1(device_1, shared_handle, d3d11.ITexture2D_UUID, cast(^rawptr)&r.video_texture), "Open video shared resource") do return false
	if !check(r.processed_texture.QueryInterface(r.processed_texture, dxgi.IKeyedMutex_UUID, cast(^rawptr)&r.capture_mutex), "Capture keyed mutex") do return false
	if !check(r.video_texture.QueryInterface(r.video_texture, dxgi.IKeyedMutex_UUID, cast(^rawptr)&r.render_mutex), "Render keyed mutex") do return false
	if !check(r.device_11.CreateShaderResourceView(r.device_11, cast(^d3d11.IResource)r.video_texture, nil, &r.rgb_view), "Video RGB shader view") do return false
	if format != .RGB24 && !video_processor_create(r, width, height) do return false
	r.resource_width = width
	r.resource_height = height
	return true
}

video_resources_release :: proc(r: ^Renderer) {
	video_enhancements_reset(r)
	if r.context_11 != nil {
		null_views := [1]^d3d11.IShaderResourceView{nil}
		r.context_11.PSSetShaderResources(r.context_11, 0, len(null_views), &null_views[0])
		r.context_11.Flush(r.context_11)
	}
	if r.capture_context_11 != nil do r.capture_context_11.Flush(r.capture_context_11)
	com_clear(&r.rgb_view)
	com_clear(&r.video_output_view)
	com_clear(&r.video_input_view)
	com_clear(&r.video_processor)
	com_clear(&r.video_enumerator)
	com_clear(&r.render_mutex)
	com_clear(&r.capture_mutex)
	com_clear(&r.video_texture)
	com_clear(&r.processed_texture)
	com_clear(&r.capture_texture)
	r.resource_width = 0
	r.resource_height = 0
	// D3D11 defers object destruction. Flush again after releasing the final
	// references so format switches and minimize promptly return their memory.
	if r.capture_context_11 != nil do r.capture_context_11.Flush(r.capture_context_11)
	if r.context_11 != nil do r.context_11.Flush(r.context_11)
}

video_processor_create :: proc(r: ^Renderer, width, height: u32) -> bool {
	if r.video_device == nil || r.video_context == nil do return false
	content := d3d11.VIDEO_PROCESSOR_CONTENT_DESC {
		InputFrameFormat = .PROGRESSIVE,
		InputFrameRate = {Numerator = 60, Denominator = 1},
		InputWidth = width, InputHeight = height,
		OutputFrameRate = {Numerator = 60, Denominator = 1},
		OutputWidth = width, OutputHeight = height,
		Usage = .OPTIMAL_SPEED,
	}
	if !check(r.video_device.CreateVideoProcessorEnumerator(r.video_device, &content, &r.video_enumerator), "Video processor enumerator") do return false
	if !check(r.video_device.CreateVideoProcessor(r.video_device, r.video_enumerator, 0, &r.video_processor), "Video processor") do return false
	input_view_desc := d3d11.VIDEO_PROCESSOR_INPUT_VIEW_DESC{ViewDimension = .TEXTURE2D}
	if !check(r.video_device.CreateVideoProcessorInputView(r.video_device, cast(^d3d11.IResource)r.capture_texture, r.video_enumerator, &input_view_desc, &r.video_input_view), "Video processor input view") do return false
	output_view_desc := d3d11.VIDEO_PROCESSOR_OUTPUT_VIEW_DESC{ViewDimension = .TEXTURE2D}
	if !check(r.video_device.CreateVideoProcessorOutputView(r.video_device, cast(^d3d11.IResource)r.processed_texture, r.video_enumerator, &output_view_desc, &r.video_output_view), "Video processor output view") do return false
	rect := win32.RECT{0, 0, i32(width), i32(height)}
	r.video_context.VideoProcessorSetStreamFrameFormat(r.video_context, r.video_processor, 0, .PROGRESSIVE)
	r.video_context.VideoProcessorSetStreamSourceRect(r.video_context, r.video_processor, 0, true, &rect)
	r.video_context.VideoProcessorSetStreamDestRect(r.video_context, r.video_processor, 0, true, &rect)
	r.video_context.VideoProcessorSetStreamAutoProcessingMode(r.video_context, r.video_processor, 0, false)
	if r.video_context_1 != nil {
		r.video_context_1.VideoProcessorSetOutputColorSpace1(r.video_context_1, r.video_processor, .RGB_FULL_G22_NONE_P709)
	} else {
		output_color := d3d11.VIDEO_PROCESSOR_COLOR_SPACE{}
		r.video_context.VideoProcessorSetOutputColorSpace(r.video_context, r.video_processor, &output_color)
	}
	return true
}

video_processor_set_color :: proc(r: ^Renderer) {
	if r.video_context == nil || r.video_processor == nil do return
	yuv_matrix := r.mode.yuv_matrix
	if yuv_matrix == 0 do yuv_matrix = 2 if r.mode.height <= 576 else 1
	// The 4K X emits video-range YUV sample values in every tested native
	// NV12/P010/YUY2 mode. Its 4K144 NV12 media type incorrectly advertises
	// full range; honoring that flag lifts 28 to 40 and 59 to 67. For I420 and
	// MJPEG compatibility modes, honor the converted output media type because
	// Windows can legitimately emit full-range NV12.
	full_range := !capture_format_is_gpu(r.capture_format) && r.mode.range == .Full
	if r.video_context_1 != nil {
		color_space := dxgi.COLOR_SPACE_TYPE.YCBCR_FULL_G22_LEFT_P709 if full_range else dxgi.COLOR_SPACE_TYPE.YCBCR_STUDIO_G22_LEFT_P709
		switch yuv_matrix {
		case 2:    color_space = .YCBCR_FULL_G22_LEFT_P601 if full_range else .YCBCR_STUDIO_G22_LEFT_P601
		case 4, 5: color_space = .YCBCR_FULL_G22_LEFT_P2020 if full_range else .YCBCR_STUDIO_G22_LEFT_P2020
		}
		r.video_context_1.VideoProcessorSetStreamColorSpace1(r.video_context_1, r.video_processor, 0, color_space)
		return
	}
	raw: u32
	if yuv_matrix != 2 do raw |= 1<<2 // 0=BT.601, 1=BT.709
	nominal := u32(2) if full_range else u32(1)
	raw |= nominal<<4
	input_color := transmute(d3d11.VIDEO_PROCESSOR_COLOR_SPACE)raw
	r.video_context.VideoProcessorSetStreamColorSpace(r.video_context, r.video_processor, 0, &input_color)
}

capture_format_dxgi :: proc(format: Capture_Format) -> dxgi.FORMAT {
	switch format {
	case .NV12: return .NV12
	case .P010: return .P010
	case .YUY2: return .YUY2
	case .RGB24: return .B8G8R8A8_UNORM
	// Planar I420 and compressed MJPEG are converted/decoded to NV12 by Media
	// Foundation before entering the D3D11 video-processor path.
	case .I420, .MJPEG: return .NV12
	}
	return .UNKNOWN
}

compile_shader :: proc(entry, target: cstring) -> ^d3dc.ID3DBlob {
	source := string(VIDEO_SHADER)
	code, errors: ^d3dc.ID3DBlob
	hr := d3dc.Compile(raw_data(source), uint(len(source)), nil, nil, nil, entry, target, u32(d3dc.D3DCOMPILE_OPTIMIZATION_LEVEL3), 0, &code, &errors)
	defer com_release(errors)
	if failed(hr) {
		fmt.eprintf("Shader compile failed (%s, 0x%08x)\n", entry, u32(hr))
		if errors != nil do fmt.eprintf("%s\n", cast(cstring)errors.GetBufferPointer(errors))
		com_release(code)
		return nil
	}
	return code
}

// The title bar occupies its own client area. Fit the entire capture below
// it, retaining the same 16:9 image when the bar appears in fullscreen.
video_viewport :: proc(width, height, top_inset: u32) -> d3d11.VIEWPORT {
	top := min(top_inset, height)
	available_height := height-top
	view_width, view_height := f32(width), f32(available_height)
	if u64(width)*9 > u64(available_height)*16 {
		view_width = view_height * 16.0 / 9.0
	} else {
		view_height = view_width * 9.0 / 16.0
	}
	return d3d11.VIEWPORT{
		TopLeftX = (f32(width)-view_width)*0.5,
		TopLeftY = f32(top)+(f32(available_height)-view_height)*0.5,
		Width = view_width,
		Height = view_height,
		MaxDepth = 1,
	}
}

video_pipeline_bind :: proc(r: ^Renderer) {
	samplers := [1]^d3d11.ISamplerState{r.sampler}
	viewport := video_viewport(r.width, r.height, r.video_top_inset)
	// Clear every region outside the video, including the reserved title bar.
	r.letterboxed = r.video_top_inset != 0 || u64(r.width)*9 != u64(r.height)*16
	r.context_11.RSSetState(r.context_11, r.rasterizer)
	r.context_11.RSSetViewports(r.context_11, 1, &viewport)
	r.context_11.IASetInputLayout(r.context_11, nil)
	r.context_11.IASetPrimitiveTopology(r.context_11, .TRIANGLELIST)
	r.context_11.VSSetShader(r.context_11, r.vertex_shader, nil, 0)
	r.context_11.PSSetSamplers(r.context_11, 0, 1, &samplers[0])
}

video_mutex_acquire :: proc(mutex: ^dxgi.IKeyedMutex, key: u64) -> bool {
	// WAIT_TIMEOUT and WAIT_ABANDONED are positive HRESULTs, not acquisitions.
	return mutex != nil && mutex.AcquireSync(mutex, key, 0) == win32.HRESULT(win32.S_OK)
}

video_pipeline_draw :: proc(r: ^Renderer, target: ^d3d11.IRenderTargetView) -> u64 {
	video_enhancements_prepare(r)
	// Key 1 consumes a new frame. Key 0 allows repainting the last frame during
	// resize or a stalled source without allocating another capture-sized texture.
	owned := video_mutex_acquire(r.render_mutex, 1) || video_mutex_acquire(r.render_mutex, 0)
	if !owned && r.enhancements.cached_view == nil do return 0
	defer { if owned do r.render_mutex.ReleaseSync(r.render_mutex, 0) }
	sequence := sync.atomic_load_explicit(&r.video_sequence, .Acquire)
	if owned do video_enhancements_submit(r, sequence)
	if owned && r.enhancements.cached_view != nil {
		// The worker copy is already submitted. Enhanced drawing uses its own
		// texture, so return capture ownership before rendering video and UI.
		r.render_mutex.ReleaseSync(r.render_mutex, 0)
		owned = false
	}
	targets := [1]^d3d11.IRenderTargetView{target}
	views := [1]^d3d11.IShaderResourceView{r.rgb_view}
	pixel_shader := r.flipped_pixel_shader if sync.atomic_load_explicit(&r.video_vertical_flip, .Acquire) != 0 else r.native_pixel_shader
	if r.enhancements.cached_view != nil {
		views[0] = r.enhancements.cached_view
		pixel_shader = r.native_pixel_shader
		sequence = r.enhancements.cached.sequence
	}
	r.context_11.OMSetRenderTargets(r.context_11, 1, &targets[0], nil)
	r.context_11.PSSetShader(r.context_11, pixel_shader, nil, 0)
	r.context_11.PSSetShaderResources(r.context_11, 0, len(views), &views[0])
	r.context_11.Draw(r.context_11, 3, 0)
	views[0] = nil
	r.context_11.PSSetShaderResources(r.context_11, 0, len(views), &views[0])
	return sequence
}

renderer_suspend_capture :: proc(r: ^Renderer) {
	if !r.ready do return
	renderer_cancel_redraw_retry(r)
	r.pending_width, r.pending_height = 0, 0
	// DXGI can dispatch size messages from inside Present. Finish the current
	// draw before releasing any textures or swap-chain buffers it still uses.
	if r.drawing || r.reconnect_thread != nil || renderer_edid_in_flight(r) {
		r.suspend_requested = true
		return
	}
	r.suspend_requested = false
	if r.capture_suspended do return
	r.suspended_resource_width = r.resource_width
	r.suspended_resource_height = r.resource_height
	capture_stop(r)
	video_resources_release(r)
	renderer_release_back_buffers(r)
	if check(renderer_resize_swap_chain(r, 1, 1), "Shrinking minimized swap chain") {
		r.width = 1
		r.height = 1
	} else {
		renderer_restore_back_buffers(r)
	}
	sync.atomic_store_explicit(&r.video_sequence, 0, .Release)
	sync.atomic_store_explicit(&r.video_vertical_flip, 0, .Release)
	r.last_presented_seq = 0
	r.capture_suspended = true
}

renderer_resume_capture :: proc(r: ^Renderer) {
	if !r.ready || !r.capture_suspended || r.reconnect_thread != nil do return
	width, height := r.suspended_resource_width, r.suspended_resource_height
	if width == 0 || height == 0 do width, height = capture_default_size(r, r.capture_format, r.requested_width == 0)
	if !video_resources_create(r, r.capture_format, width, height) {
		fmt.eprintln("Could not restore capture resources after minimize")
		return
	}
	r.capture_suspended = false
	r.suspended_resource_width = 0
	r.suspended_resource_height = 0
	video_pipeline_bind(r)
	if !capture_start(r) {
		fmt.eprintln("Could not resume capture after minimize")
	}
}

renderer_set_capture_format :: proc(r: ^Renderer, format: Capture_Format) {
	if renderer_edid_busy(r) || !capture_format_available(r, format) do return
	if format == r.capture_format {
		r.format_auto = false
		return
	}
	config := Capture_Config{capture_format = format, requested_width = r.requested_width, requested_height = r.requested_height}
	if config.requested_width != 0 && !capture_resolution_available_for_format(r, format, config.requested_width, config.requested_height) {
		config.requested_width, config.requested_height = 0, 0
	}
	renderer_apply_capture_configuration(r, config)
}

renderer_set_capture_format_auto :: proc(r: ^Renderer) {
	if renderer_edid_busy(r) do return
	format, found := capture_pick_auto_format(r, r.requested_width, r.requested_height)
	if !found || format == r.capture_format {
		r.format_auto = true
		return
	}
	renderer_apply_capture_configuration(r, {capture_format = format, format_auto = true, requested_width = r.requested_width, requested_height = r.requested_height})
}

// A zero size selects Auto.
renderer_set_capture_resolution :: proc(r: ^Renderer, width, height: u32) {
	if renderer_edid_busy(r) do return
	config := Capture_Config{capture_format = r.capture_format, format_auto = r.format_auto}
	if width != 0 && height != 0 {
		if !capture_resolution_available(r, width, height) do return
		config.requested_width, config.requested_height = width, height
	}
	if config.requested_width == r.requested_width && config.requested_height == r.requested_height do return
	if r.format_auto {
		if preferred, found := capture_pick_auto_format(r, config.requested_width, config.requested_height); found do config.capture_format = preferred
	}
	renderer_apply_capture_configuration(r, config)
}

// Restarts capture with config. A zero resource size picks the texture size
// from the requested resolution or the best enumerated mode.
renderer_apply_capture_configuration :: proc(r: ^Renderer, config: Capture_Config) {
	if !r.ready || r.capture_suspended || r.reconnect_thread != nil || renderer_edid_in_flight(r) do return
	previous := r.config
	if sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0 {
		r.last_working = previous
		r.last_working_valid = true
	}
	width, height := config.resource_width, config.resource_height
	if width == 0 || height == 0 {
		width, height = config.requested_width, config.requested_height
		if width == 0 || height == 0 do width, height = capture_default_size(r, config.capture_format, true)
	}
	capture_stop(r)
	video_resources_release(r)
	r.config = config
	if !video_resources_create(r, config.capture_format, width, height) {
		fmt.eprintf("Could not create %s %dx%d GPU resources; restoring previous mode\n", CAPTURE_FORMAT_NAME[config.capture_format], width, height)
		r.config = previous
		if !video_resources_create(r, previous.capture_format, previous.resource_width, previous.resource_height) {
			r.ready = false
			fmt.eprintln("Could not restore capture GPU resources")
			return
		}
	}
	r.mode = {}
	r.last_presented_seq = 0
	sync.atomic_store_explicit(&r.video_sequence, 0, .Release)
	sync.atomic_store_explicit(&r.video_vertical_flip, 0, .Release)
	video_pipeline_bind(r)
	if !capture_start(r) {
		fmt.eprintln("Could not restart capture")
		renderer_handle_capture_failure(r, sync.atomic_load_explicit(&r.capture_generation, .Acquire))
	}
}

renderer_handle_capture_failure :: proc(r: ^Renderer, generation: u32) {
	if !r.ready || r.capture_suspended || r.reconnect_thread != nil do return
	if generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) do return
	if sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0 do return
	if !r.last_working_valid {
		renderer_reconcile_auto_capture(r)
		return
	}
	r.last_working_valid = false
	restore := r.last_working
	if r.capture_format == restore.capture_format && r.requested_width == restore.requested_width && r.requested_height == restore.requested_height do return
	fmt.eprintf("Capture negotiation failed for %s; restoring %s\n", CAPTURE_FORMAT_NAME[r.capture_format], CAPTURE_FORMAT_NAME[restore.capture_format])
	renderer_apply_capture_configuration(r, restore)
}

// Startup uses a provisional NV12/4K allocation before the device's modes are
// known. Resolve Auto after enumeration, including devices without that mode.
renderer_reconcile_auto_capture :: proc(r: ^Renderer) {
	if !r.ready || !r.format_auto || r.capture_suspended || r.startup_auto_resolved || r.reconnect_thread != nil do return
	format, found := capture_pick_auto_format(r, r.requested_width, r.requested_height)
	if !found do return
	r.startup_auto_resolved = true
	width, height := r.requested_width, r.requested_height
	if width == 0 {
		best, best_found := capture_best_mode(r, format, 0, 0, true)
		if !best_found do return
		width, height = best.width, best.height
	}
	if format == r.capture_format && width == r.resource_width && height == r.resource_height do return
	renderer_apply_capture_configuration(r, {
		capture_format = format, format_auto = true,
		requested_width = r.requested_width, requested_height = r.requested_height,
		resource_width = width, resource_height = height,
	})
}
