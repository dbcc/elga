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

Renderer :: struct {
	ready:          bool,
	hwnd:           win32.HWND,
	width:          u32,
	height:         u32,
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
	video_sequence: u64,
	video_vertical_flip: u32,
	redraw_pending: u32,
	capture_running: bool,
	capture_ready:   u32,
	capture_refresh: u32,
	capture_thread:  ^thread.Thread,
	capture_event:   win32.HANDLE,
	capture_generation: u32,
	capture_suspended: bool,
	suspended_resource_width: u32,
	suspended_resource_height: u32,
	capture_width:   u32,
	capture_height:  u32,
	capture_fps_num: u32,
	capture_fps_den: u32,
	capture_matrix:  u32,
	capture_range:   Video_Range,
	capture_stride:  i32,
	capture_format:  Capture_Format,
	capture_formats: u32,
	capture_mode_indices: [MAX_CAPTURE_MODES]u16,
	capture_mode_count: u32,
	source_modes:    [MAX_CAPTURE_MODES]Capture_Mode,
	source_mode_count: u32,
	format_auto:     bool,
	startup_auto_resolved: bool,
	requested_width:  u32,
	requested_height: u32,
	resource_width:   u32,
	resource_height:  u32,
	last_working_valid: bool,
	last_working_format: Capture_Format,
	last_working_format_auto: bool,
	last_working_requested_width: u32,
	last_working_requested_height: u32,
	last_working_resource_width: u32,
	last_working_resource_height: u32,
	display_fps:        f64,
	fps_window_start:   time.Time,
	fps_window_frames:  u32,
	last_presented_seq: u64,
	last_video_present: time.Time,
}

renderer_request_redraw :: proc(r: ^Renderer) {
	if r == nil || r.hwnd == nil do return
	if sync.atomic_exchange_explicit(&r.redraw_pending, 1, .Relaxed) == 0 {
		if !bool(win32.PostMessageW(r.hwnd, FRAME_READY_MESSAGE, 0, 0)) {
			sync.atomic_store_explicit(&r.redraw_pending, 0, .Relaxed)
		}
	}
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
	sync.atomic_store_explicit(&r.capture_formats, u32(1)<<u32(Capture_Format.NV12), .Relaxed)

	factory: ^dxgi.IFactory4
	hr := dxgi.CreateDXGIFactory2({}, dxgi.IFactory4_UUID, cast(^rawptr)&factory)
	if !renderer_init_ok("CreateDXGIFactory2", hr) do return false
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
	hr = d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, &feature_levels[0], 1, d3d11.SDK_VERSION, &r.device_11, nil, &r.context_11)
	if !renderer_init_ok("render D3D11CreateDevice", hr) do return false
	hr = d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT, .VIDEO_SUPPORT}, &feature_levels[0], 1, d3d11.SDK_VERSION, &r.capture_device_11, nil, &r.capture_context_11)
	if !renderer_init_ok("capture D3D11CreateDevice", hr) do return false
	multithread: ^ID3D10Multithread
	hr = r.capture_device_11.QueryInterface(r.capture_device_11, ID3D10Multithread_UUID, cast(^rawptr)&multithread)
	if !renderer_init_ok("capture multithread protection", hr) do return false
	multithread.SetMultithreadProtected(multithread, true)
	com_release(multithread)
	hr_video := r.capture_device_11.QueryInterface(r.capture_device_11, d3d11.IVideoDevice_UUID, cast(^rawptr)&r.video_device)
	if failed(hr_video) { fmt.eprintf("IVideoDevice unavailable: 0x%08x\n", u32(hr_video)); return false }
	hr_video = r.capture_context_11.QueryInterface(r.capture_context_11, d3d11.IVideoContext_UUID, cast(^rawptr)&r.video_context)
	if failed(hr_video) { fmt.eprintf("IVideoContext unavailable: 0x%08x\n", u32(hr_video)); return false }
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
		Flags       = {.ALLOW_TEARING} if r.allow_tearing else {},
	}

	swap1: ^dxgi.ISwapChain1
	hr = factory.CreateSwapChainForHwnd(factory, cast(^dxgi.IUnknown)r.device_11, hwnd, &swap_desc, nil, nil, &swap1)
	if !renderer_init_ok("CreateSwapChainForHwnd", hr) do return false
	defer com_release(swap1)
	hr = swap1.QueryInterface(swap1, dxgi.ISwapChain3_UUID, cast(^rawptr)&r.swap_chain)
	if !renderer_init_ok("swap chain 3 interface", hr) do return false
	factory.MakeWindowAssociation(factory, hwnd, {.NO_ALT_ENTER})
	r.fps_window_start = time.now()

	if !renderer_create_back_buffers(r) do return false
	if !video_pipeline_init(r) do return false
	if !capture_start(r) do return false
	r.ready = true
	return true
}

renderer_create_back_buffers :: proc(r: ^Renderer) -> bool {
	hr := r.swap_chain.GetBuffer(r.swap_chain, 0, d3d11.ITexture2D_UUID, cast(^rawptr)&r.back_buffer)
	if failed(hr) {
		fmt.eprintf("Swap-chain buffer failed: 0x%08x\n", u32(hr))
		return false
	}
	hr = r.device_11.CreateRenderTargetView(r.device_11, cast(^d3d11.IResource)r.back_buffer, nil, &r.target)
	if failed(hr) {
		fmt.eprintf("Swap-chain render target failed: 0x%08x\n", u32(hr))
		renderer_release_back_buffers(r)
		return false
	}
	return true
}

renderer_draw :: proc(r: ^Renderer) {
	if !r.ready || r.width == 0 || r.height == 0 do return
	frame_allocator := mem.arena_allocator(&app.frame_arena)
	context.allocator = frame_allocator
	context.temp_allocator = frame_allocator
	defer mem.arena_free_all(&app.frame_arena)

	if r.target == nil do return
	sequence := sync.atomic_load_explicit(&r.video_sequence, .Acquire)
	capture_ready := sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0
	presented_sequence: u64

	clear := [4]f32{0, 0, 0, 1}
	cleared := sequence == 0 || !capture_ready || r.letterboxed
	if cleared do r.context_11.ClearRenderTargetView(r.context_11, r.target, &clear)
	if sequence != 0 && capture_ready {
		// Keep the previous presentation on screen while capture owns the surface.
		presented_sequence = video_pipeline_draw(r, r.target)
		if presented_sequence == 0 do return
	}

	// Skip all ImGui work while the fullscreen title bar is hidden.
	overlay_visible := app.ui.ready && (app.controls_visible || app.ui.menu_open)
	if overlay_visible {
		draw_data := imgui_ui_new_frame(&app.ui, r)
		targets := [1]^d3d11.IRenderTargetView{r.target}
		r.context_11.OMSetRenderTargets(r.context_11, 1, &targets[0], nil)
		imgui_ui_render(&app.ui, draw_data)
	}

	present_flags := dxgi.PRESENT{.ALLOW_TEARING} if r.allow_tearing else dxgi.PRESENT{}
	if failed(r.swap_chain.Present(r.swap_chain, 0, present_flags)) do return
	now := time.now()
	if presented_sequence != 0 && presented_sequence != r.last_presented_seq {
		r.last_presented_seq = presented_sequence
		r.last_video_present = now
		r.fps_window_frames += 1
	}
	elapsed := time.duration_seconds(time.diff(r.fps_window_start, now))
	if elapsed >= 0.5 {
		r.display_fps = f64(r.fps_window_frames) / elapsed
		r.fps_window_frames = 0
		r.fps_window_start = now
	}
}

renderer_resize :: proc(r: ^Renderer, width, height: u32) {
	if !r.ready || width == 0 || height == 0 || (r.width == width && r.height == height) do return
	renderer_release_back_buffers(r)

	// ResizeBuffers must preserve ALLOW_TEARING from swap-chain creation.
	resize_flags := dxgi.SWAP_CHAIN{.ALLOW_TEARING} if r.allow_tearing else dxgi.SWAP_CHAIN{}
	hr := r.swap_chain.ResizeBuffers(r.swap_chain, SWAP_CHAIN_BUFFER_COUNT, width, height, .R8G8B8A8_UNORM, resize_flags)
	if failed(hr) {
		fmt.eprintf("ResizeBuffers failed: 0x%08x; restoring existing buffers\n", u32(hr))
		renderer_restore_back_buffers(r)
		return
	}
	r.width = width
	r.height = height
	if !renderer_restore_back_buffers(r) {
		fmt.eprintln("Could not recreate swap-chain render targets")
	}
}

renderer_restore_back_buffers :: proc(r: ^Renderer) -> bool {
	if !renderer_create_back_buffers(r) {
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
	com_release(r.target)
	com_release(r.back_buffer)
	r.target = nil
	r.back_buffer = nil
	if r.context_11 != nil do r.context_11.Flush(r.context_11)
}

renderer_destroy :: proc(r: ^Renderer) {
	if r == nil do return
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
	vs := compile_shader(cstring("VSMain"), cstring("vs_5_0"))
	if vs == nil do return false
	defer com_release(vs)
	hr := r.device_11.CreateVertexShader(r.device_11, vs.GetBufferPointer(vs), vs.GetBufferSize(vs), nil, &r.vertex_shader)
	if failed(hr) {
		fmt.eprintf("Video vertex shader creation failed: 0x%08x\n", u32(hr))
		return false
	}
	if !create_pixel_shader(r, "PSNativeRGB", &r.native_pixel_shader) {
		fmt.eprintln("Native RGB pixel shader creation failed")
		return false
	}
	if !create_pixel_shader(r, "PSNativeRGBFlipped", &r.flipped_pixel_shader) {
		fmt.eprintln("Flipped RGB pixel shader creation failed")
		return false
	}

	sampler_desc := d3d11.SAMPLER_DESC{Filter = .MIN_MAG_LINEAR_MIP_POINT, AddressU = .CLAMP, AddressV = .CLAMP, AddressW = .CLAMP, MaxLOD = 3.402823466e+38}
	if failed(r.device_11.CreateSamplerState(r.device_11, &sampler_desc, &r.sampler)) {
		fmt.eprintln("Video sampler creation failed")
		return false
	}
	raster_desc := d3d11.RASTERIZER_DESC{FillMode = .SOLID, CullMode = .NONE, DepthClipEnable = true}
	if failed(r.device_11.CreateRasterizerState(r.device_11, &raster_desc, &r.rasterizer)) {
		fmt.eprintln("Video rasterizer creation failed")
		return false
	}
	if !video_resources_create(r, r.capture_format, CAPTURE_AUTO_WIDTH, CAPTURE_AUTO_HEIGHT) do return false
	video_pipeline_bind(r)
	return true
}

create_pixel_shader :: proc(r: ^Renderer, entry: cstring, shader: ^^d3d11.IPixelShader) -> bool {
	code := compile_shader(entry, "ps_5_0")
	if code == nil do return false
	defer com_release(code)
	return !failed(r.device_11.CreatePixelShader(r.device_11, code.GetBufferPointer(code), code.GetBufferSize(code), nil, shader))
}

video_resources_create :: proc(r: ^Renderer, format: Capture_Format, width, height: u32) -> (success: bool) {
	defer {
		if !success do video_resources_release(r)
	}
	hr_resource: win32.HRESULT
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
		hr_resource = r.capture_device_11.CreateTexture2D(r.capture_device_11, &input_desc, nil, &r.capture_texture)
		if failed(hr_resource) { fmt.eprintf("Video input texture failed: 0x%08x\n", u32(hr_resource)); return false }
	}
	output_desc := d3d11.TEXTURE2D_DESC {
		Width = width, Height = height, MipLevels = 1, ArraySize = 1,
		Format = .B8G8R8A8_UNORM, SampleDesc = {Count = 1}, Usage = .DEFAULT,
		BindFlags = {.RENDER_TARGET, .SHADER_RESOURCE}, MiscFlags = {.SHARED_KEYEDMUTEX, .SHARED_NTHANDLE},
	}
	hr_resource = r.capture_device_11.CreateTexture2D(r.capture_device_11, &output_desc, nil, &r.processed_texture)
	if failed(hr_resource) { fmt.eprintf("Video output texture failed: 0x%08x\n", u32(hr_resource)); return false }
	shared_resource: ^dxgi.IResource1
	hr_resource = r.processed_texture.QueryInterface(r.processed_texture, dxgi.IResource1_UUID, cast(^rawptr)&shared_resource)
	if failed(hr_resource) { fmt.eprintf("Video output IDXGIResource1 failed: 0x%08x\n", u32(hr_resource)); return false }
	defer com_release(shared_resource)
	shared_handle: win32.HANDLE
	hr_resource = shared_resource.CreateSharedHandle(shared_resource, nil, {.READ, .WRITE}, nil, &shared_handle)
	if failed(hr_resource) { fmt.eprintf("Video shared handle failed: 0x%08x\n", u32(hr_resource)); return false }
	defer win32.CloseHandle(shared_handle)

	device_1: ^ID3D11Device1
	hr_resource = r.device_11.QueryInterface(r.device_11, ID3D11Device1_UUID, cast(^rawptr)&device_1)
	if failed(hr_resource) { fmt.eprintf("Render ID3D11Device1 failed: 0x%08x\n", u32(hr_resource)); return false }
	defer com_release(device_1)
	hr_resource = device_1.OpenSharedResource1(device_1, shared_handle, d3d11.ITexture2D_UUID, cast(^rawptr)&r.video_texture)
	if failed(hr_resource) { fmt.eprintf("Open video shared resource failed: 0x%08x\n", u32(hr_resource)); return false }
	hr_resource = r.processed_texture.QueryInterface(r.processed_texture, dxgi.IKeyedMutex_UUID, cast(^rawptr)&r.capture_mutex)
	if failed(hr_resource) { fmt.eprintf("Capture keyed mutex failed: 0x%08x\n", u32(hr_resource)); return false }
	hr_resource = r.video_texture.QueryInterface(r.video_texture, dxgi.IKeyedMutex_UUID, cast(^rawptr)&r.render_mutex)
	if failed(hr_resource) { fmt.eprintf("Render keyed mutex failed: 0x%08x\n", u32(hr_resource)); return false }
	hr_resource = r.device_11.CreateShaderResourceView(r.device_11, cast(^d3d11.IResource)r.video_texture, nil, &r.rgb_view)
	if failed(hr_resource) { fmt.eprintf("Video RGB shader view failed: 0x%08x\n", u32(hr_resource)); return false }
	// RGB24 has already been expanded to a display-ready BGRA surface by Media
	// Foundation, so it bypasses the optional D3D11 RGB video-processor input.
	if format != .RGB24 && !video_processor_create(r, width, height) do return false
	r.resource_width = width
	r.resource_height = height
	return true
}

video_resources_release :: proc(r: ^Renderer) {
	if r.context_11 != nil {
		null_views := [1]^d3d11.IShaderResourceView{nil}
		r.context_11.PSSetShaderResources(r.context_11, 0, len(null_views), &null_views[0])
		r.context_11.Flush(r.context_11)
	}
	if r.capture_context_11 != nil do r.capture_context_11.Flush(r.capture_context_11)
	com_release(r.rgb_view)
	com_release(r.video_output_view)
	com_release(r.video_input_view)
	com_release(r.video_processor)
	com_release(r.video_enumerator)
	com_release(r.render_mutex)
	com_release(r.capture_mutex)
	com_release(r.video_texture)
	com_release(r.processed_texture)
	com_release(r.capture_texture)
	r.rgb_view = nil
	r.video_output_view = nil
	r.video_input_view = nil
	r.video_processor = nil
	r.video_enumerator = nil
	r.render_mutex = nil
	r.capture_mutex = nil
	r.video_texture = nil
	r.processed_texture = nil
	r.capture_texture = nil
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
	hr := r.video_device.CreateVideoProcessorEnumerator(r.video_device, &content, &r.video_enumerator)
	if failed(hr) { fmt.eprintf("Video processor enumerator failed: 0x%08x\n", u32(hr)); return false }
	hr = r.video_device.CreateVideoProcessor(r.video_device, r.video_enumerator, 0, &r.video_processor)
	if failed(hr) { fmt.eprintf("Video processor failed: 0x%08x\n", u32(hr)); return false }
	input_view_desc := d3d11.VIDEO_PROCESSOR_INPUT_VIEW_DESC{ViewDimension = .TEXTURE2D}
	hr = r.video_device.CreateVideoProcessorInputView(r.video_device, cast(^d3d11.IResource)r.capture_texture, r.video_enumerator, &input_view_desc, &r.video_input_view)
	if failed(hr) { fmt.eprintf("Video processor input view failed: 0x%08x\n", u32(hr)); return false }
	output_view_desc := d3d11.VIDEO_PROCESSOR_OUTPUT_VIEW_DESC{ViewDimension = .TEXTURE2D}
	hr = r.video_device.CreateVideoProcessorOutputView(r.video_device, cast(^d3d11.IResource)r.processed_texture, r.video_enumerator, &output_view_desc, &r.video_output_view)
	if failed(hr) { fmt.eprintf("Video processor output view failed: 0x%08x\n", u32(hr)); return false }
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
	yuv_matrix := r.capture_matrix
	if yuv_matrix == 0 do yuv_matrix = 2 if r.capture_height <= 576 else 1
	// Preserve the card's empirically verified video-range encoding for direct
	// GPU modes. For I420 and MJPEG compatibility modes, honor the converted
	// output media type because Windows can legitimately emit full-range NV12.
	full_range := !capture_format_is_gpu(r.capture_format) && r.capture_range == .Full
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
	// The 4K X emits video-range YUV sample values in every tested native
	// NV12/P010/YUY2 mode. Its 4K144 NV12 media type incorrectly advertises
	// full range; honoring that flag lifts 28 to 40 and 59 to 67. Describe the
	// actual sample encoding to the GPU video processor without modifying it.
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
	if failed(hr) {
		fmt.eprintf("Shader compile failed (%s, 0x%08x)\n", entry, u32(hr))
		if errors != nil do fmt.eprintf("%s\n", cast(cstring)errors.GetBufferPointer(errors))
	}
	if errors != nil do com_release(errors)
	if failed(hr) {
		com_release(code)
		return nil
	}
	return code
}

video_pipeline_bind :: proc(r: ^Renderer) {
	samplers := [1]^d3d11.ISamplerState{r.sampler}
	view_width, view_height := f32(r.width), f32(r.height)
	r.letterboxed = u64(r.width)*9 != u64(r.height)*16
	if u64(r.width)*9 > u64(r.height)*16 {
		view_width = view_height * 16.0 / 9.0
	} else {
		view_height = view_width * 9.0 / 16.0
	}
	viewport := d3d11.VIEWPORT{
		TopLeftX = (f32(r.width)-view_width)*0.5,
		TopLeftY = (f32(r.height)-view_height)*0.5,
		Width = view_width,
		Height = view_height,
		MaxDepth = 1,
	}
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
	// Key 1 consumes a new frame. Key 0 allows repainting the last frame during
	// resize or a stalled source without allocating another capture-sized texture.
	if !video_mutex_acquire(r.render_mutex, 1) && !video_mutex_acquire(r.render_mutex, 0) do return 0
	defer r.render_mutex.ReleaseSync(r.render_mutex, 0)
	sequence := sync.atomic_load_explicit(&r.video_sequence, .Acquire)
	targets := [1]^d3d11.IRenderTargetView{target}
	views := [1]^d3d11.IShaderResourceView{r.rgb_view}
	pixel_shader := r.flipped_pixel_shader if sync.atomic_load_explicit(&r.video_vertical_flip, .Acquire) != 0 else r.native_pixel_shader
	r.context_11.OMSetRenderTargets(r.context_11, 1, &targets[0], nil)
	r.context_11.PSSetShader(r.context_11, pixel_shader, nil, 0)
	r.context_11.PSSetShaderResources(r.context_11, 0, len(views), &views[0])
	r.context_11.Draw(r.context_11, 3, 0)
	null_views := [1]^d3d11.IShaderResourceView{nil}
	r.context_11.PSSetShaderResources(r.context_11, 0, len(null_views), &null_views[0])
	return sequence
}

renderer_set_capture_format :: proc(r: ^Renderer, format: Capture_Format) {
	if !capture_format_available(r, format) do return
	if format == r.capture_format {
		r.format_auto = false
		return
	}
	requested_width, requested_height := r.requested_width, r.requested_height
	if requested_width != 0 && !capture_resolution_available_for_format(r, format, requested_width, requested_height) {
		requested_width, requested_height = 0, 0
	}
	renderer_apply_capture_configuration(r, format, requested_width, requested_height, false)
}

renderer_suspend_capture :: proc(r: ^Renderer) {
	if !r.ready || r.capture_suspended do return
	r.suspended_resource_width = r.resource_width
	r.suspended_resource_height = r.resource_height
	capture_stop(r)
	video_resources_release(r)
	renderer_release_back_buffers(r)
	resize_flags := dxgi.SWAP_CHAIN{.ALLOW_TEARING} if r.allow_tearing else dxgi.SWAP_CHAIN{}
	hr := r.swap_chain.ResizeBuffers(r.swap_chain, SWAP_CHAIN_BUFFER_COUNT, 1, 1, .R8G8B8A8_UNORM, resize_flags)
	if failed(hr) {
		fmt.eprintf("Could not shrink minimized swap chain: 0x%08x\n", u32(hr))
		renderer_restore_back_buffers(r)
	} else {
		r.width = 1
		r.height = 1
	}
	sync.atomic_store_explicit(&r.video_sequence, 0, .Release)
	sync.atomic_store_explicit(&r.video_vertical_flip, 0, .Release)
	r.last_presented_seq = 0
	r.capture_suspended = true
}

renderer_resume_capture :: proc(r: ^Renderer) {
	if !r.ready || !r.capture_suspended do return
	width := r.suspended_resource_width
	height := r.suspended_resource_height
	if width == 0 || height == 0 {
		best, found := capture_pick_best_mode_for_format(r, r.capture_format)
		if found {
			width, height = best.width, best.height
		} else {
			width, height = CAPTURE_AUTO_WIDTH, CAPTURE_AUTO_HEIGHT
		}
	}
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

renderer_set_capture_format_auto :: proc(r: ^Renderer) {
	format, found := capture_pick_auto_format(r, r.requested_width, r.requested_height)
	if !found || format == r.capture_format {
		r.format_auto = true
		return
	}
	renderer_apply_capture_configuration(r, format, r.requested_width, r.requested_height, true)
}

renderer_set_capture_resolution :: proc(r: ^Renderer, width, height: u32) {
	requested_width, requested_height := width, height
	if requested_width == 0 || requested_height == 0 {
		requested_width, requested_height = 0, 0
	} else if !capture_resolution_available(r, requested_width, requested_height) {
		return
	}
	if requested_width == r.requested_width && requested_height == r.requested_height do return
	format := r.capture_format
	if r.format_auto {
		preferred, found := capture_pick_auto_format(r, requested_width, requested_height)
		if found do format = preferred
	}
	renderer_apply_capture_configuration(r, format, requested_width, requested_height, r.format_auto)
}

renderer_apply_capture_configuration :: proc(
	r: ^Renderer,
	format: Capture_Format,
	requested_width, requested_height: u32,
	format_auto: bool,
	target_override_width := u32(0),
	target_override_height := u32(0),
) {
	previous_format := r.capture_format
	previous_format_auto := r.format_auto
	previous_requested_width := r.requested_width
	previous_requested_height := r.requested_height
	previous_resource_width := r.resource_width
	previous_resource_height := r.resource_height
	if sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0 {
		r.last_working_valid = true
		r.last_working_format = previous_format
		r.last_working_format_auto = previous_format_auto
		r.last_working_requested_width = previous_requested_width
		r.last_working_requested_height = previous_requested_height
		r.last_working_resource_width = previous_resource_width
		r.last_working_resource_height = previous_resource_height
	}
	target_width := requested_width
	target_height := requested_height
	if target_override_width != 0 && target_override_height != 0 {
		target_width, target_height = target_override_width, target_override_height
	} else if target_width == 0 || target_height == 0 {
		best, found := capture_pick_best_mode_for_format(r, format)
		if found {
			target_width, target_height = best.width, best.height
		} else {
			target_width, target_height = CAPTURE_AUTO_WIDTH, CAPTURE_AUTO_HEIGHT
		}
	}
	capture_stop(r)
	video_resources_release(r)
	r.capture_format = format
	r.format_auto = format_auto
	r.requested_width = requested_width
	r.requested_height = requested_height
	if !video_resources_create(r, format, target_width, target_height) {
		fmt.eprintf("Could not create %s %dx%d GPU resources; restoring previous mode\n", capture_format_name(format), target_width, target_height)
		r.capture_format = previous_format
		r.format_auto = previous_format_auto
		r.requested_width = previous_requested_width
		r.requested_height = previous_requested_height
		if !video_resources_create(r, previous_format, previous_resource_width, previous_resource_height) {
			r.ready = false
			fmt.eprintln("Could not restore capture GPU resources")
			return
		}
	}
	r.capture_width = 0
	r.capture_height = 0
	r.capture_fps_num = 0
	r.capture_fps_den = 0
	r.capture_matrix = 0
	r.capture_range = .Unknown
	r.capture_stride = 0
	r.last_presented_seq = 0
	sync.atomic_store_explicit(&r.video_sequence, 0, .Release)
	sync.atomic_store_explicit(&r.video_vertical_flip, 0, .Release)
	video_pipeline_bind(r)
	if !capture_start(r) {
		fmt.eprintln("Could not restart capture")
		generation := sync.atomic_load_explicit(&r.capture_generation, .Acquire)
		renderer_handle_capture_failure(r, generation)
	}
}

renderer_handle_capture_failure :: proc(r: ^Renderer, generation: u32) {
	if !r.ready || r.capture_suspended do return
	if generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) do return
	if sync.atomic_load_explicit(&r.capture_ready, .Acquire) != 0 do return
	if !r.last_working_valid {
		renderer_reconcile_auto_capture(r)
		return
	}
	if r.capture_format == r.last_working_format &&
	   r.requested_width == r.last_working_requested_width &&
	   r.requested_height == r.last_working_requested_height {
		r.last_working_valid = false
		return
	}
	fmt.eprintf("Capture negotiation failed for %s; restoring %s\n", capture_format_name(r.capture_format), capture_format_name(r.last_working_format))
	format := r.last_working_format
	format_auto := r.last_working_format_auto
	requested_width := r.last_working_requested_width
	requested_height := r.last_working_requested_height
	resource_width := r.last_working_resource_width
	resource_height := r.last_working_resource_height
	r.last_working_valid = false
	renderer_apply_capture_configuration(r, format, requested_width, requested_height, format_auto, resource_width, resource_height)
}

// Startup uses a provisional NV12/4K allocation before the device's modes are
// known. Resolve Auto after enumeration, including devices without that mode.
renderer_reconcile_auto_capture :: proc(r: ^Renderer) {
	if !r.ready || !r.format_auto || r.capture_suspended || r.startup_auto_resolved do return
	format, found := capture_pick_auto_format(r, r.requested_width, r.requested_height)
	if !found do return
	r.startup_auto_resolved = true
	width, height := r.requested_width, r.requested_height
	if width == 0 {
		best, best_found := capture_pick_best_mode_for_format(r, format)
		if !best_found do return
		width, height = best.width, best.height
	}
	if format == r.capture_format && width == r.resource_width && height == r.resource_height do return
	renderer_apply_capture_configuration(r, format, r.requested_width, r.requested_height, true, width, height)
}

failed :: proc(hr: win32.HRESULT) -> bool {
	return win32.FAILED(hr)
}

com_release :: proc(p: $T) {
	if p != nil {
		unknown := cast(^win32.IUnknown)p
		unknown.Release(unknown)
	}
}

renderer_init_ok :: proc(stage: string, hr: win32.HRESULT) -> bool {
	if !failed(hr) do return true
	fmt.eprintf("Renderer initialization failed at %s: 0x%08x\n", stage, u32(hr))
	return false
}
