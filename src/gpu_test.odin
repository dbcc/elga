package main

import "core:mem"
import "core:testing"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"

foreign import gpu_mfplat_lib "system:mfplat.lib"
foreign gpu_mfplat_lib {
	MFCreateSample :: proc "system" (sample: ^^IMFSample) -> win32.HRESULT ---
	MFCreateMemoryBuffer :: proc "system" (length: u32, buffer: ^^IMFMediaBuffer) -> win32.HRESULT ---
	MFCreate2DMediaBuffer :: proc "system" (width, height, fourcc: u32, bottom_up: win32.BOOL, buffer: ^^IMFMediaBuffer) -> win32.HRESULT ---
	MFCreateDXGISurfaceBuffer :: proc "system" (iid: ^win32.GUID, surface: ^win32.IUnknown, subresource: u32, bottom_up: win32.BOOL, buffer: ^^IMFMediaBuffer) -> win32.HRESULT ---
}

// Opt in on a Windows machine with a D3D11 video-capable GPU. Uses synthetic
// black/gradient frames; no capture card, audio device, or window is needed.
when #config(ELGA_GPU_TESTS, false) {
	@(test)
	capture_gpu_roundtrip_test :: proc(t: ^testing.T) {
		capture_gpu_roundtrip(t)
	}
}

capture_gpu_roundtrip :: proc(t: ^testing.T) {
	if !testing.expect(t, !failed(win32.CoInitializeEx(nil, .MULTITHREADED))) do return
	defer win32.CoUninitialize()
	if !testing.expect(t, !failed(MFStartup(MF_VERSION, MFSTARTUP_FULL))) do return
	defer MFShutdown()
	r: Renderer
	defer renderer_destroy(&r)
	levels := [1]d3d11.FEATURE_LEVEL{._11_0}
	if !testing.expect(t, !failed(d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT}, &levels[0], 1, d3d11.SDK_VERSION, &r.device_11, nil, &r.context_11))) do return
	if !testing.expect(t, !failed(d3d11.CreateDevice(nil, .HARDWARE, nil, {.BGRA_SUPPORT, .VIDEO_SUPPORT}, &levels[0], 1, d3d11.SDK_VERSION, &r.capture_device_11, nil, &r.capture_context_11))) do return
	if !testing.expect(t, !failed(r.capture_device_11.QueryInterface(r.capture_device_11, d3d11.IVideoDevice_UUID, cast(^rawptr)&r.video_device))) do return
	if !testing.expect(t, !failed(r.capture_context_11.QueryInterface(r.capture_context_11, d3d11.IVideoContext_UUID, cast(^rawptr)&r.video_context))) do return
	r.capture_context_11.QueryInterface(r.capture_context_11, ID3D11VideoContext1_UUID, cast(^rawptr)&r.video_context_1)
	r.width, r.height = 32, 18
	if !testing.expect(t, video_pipeline_init(&r)) do return
	video_resources_release(&r)
	for path_format in 0..<CAPTURE_FORMAT_COUNT*3+1 {
		gpu_surface := path_format >= CAPTURE_FORMAT_COUNT && path_format < CAPTURE_FORMAT_COUNT*2
		software_2d := path_format >= CAPTURE_FORMAT_COUNT*2
		bottom_up := path_format == CAPTURE_FORMAT_COUNT*3
		format := Capture_Format(path_format%CAPTURE_FORMAT_COUNT)
		if bottom_up do format = .RGB24
		r.capture_format = format
		r.capture_width, r.capture_height = 32, 18
		r.capture_matrix = 1
		r.capture_range = .Limited
		r.video_sequence = 0
		if !testing.expect(t, video_resources_create(&r, format, 32, 18)) do return
		defer video_resources_release(&r)
		video_processor_set_color(&r)
		// GPU sources deliberately have padding on both axes.
		source_width := 64 if gpu_surface else 32
		source_height := 32 if gpu_surface else 18
		source_pixels := source_width*source_height
		pixels: [64*32*4]byte
		length := source_pixels*3/2
		switch format {
		case .NV12, .I420, .MJPEG:
			for i in 0..<length do pixels[i] = 16 if i < source_pixels else 128
		case .P010:
			length *= 2
			for i := 1; i < length; i += 2 do pixels[i] = 16 if i < source_pixels*2 else 128
		case .YUY2:
			length = source_pixels*2
			for i in 0..<length do pixels[i] = 16 if i%2 == 0 else 128
		case .RGB24:
			length = source_pixels*4
			for i := 0; i < length; i += 4 {
				row := u8(i/(source_width*4))
				pixels[i], pixels[i+1], pixels[i+2], pixels[i+3] = 20+row, 40+row, 60+row, 255
			}
		}
		buffer: ^IMFMediaBuffer
		defer com_release(buffer)
		if gpu_surface {
			source: ^d3d11.ITexture2D
			source_desc := d3d11.TEXTURE2D_DESC{
				Width = u32(source_width), Height = u32(source_height), MipLevels = 1, ArraySize = 1,
				Format = capture_format_dxgi(format), SampleDesc = {Count = 1}, Usage = .DEFAULT,
			}
			pitch, valid := capture_upload_pitch(format, u32(source_width), u32(source_height), 0, u32(length))
			if !testing.expect(t, valid) do return
			initial := d3d11.SUBRESOURCE_DATA{pSysMem = &pixels[0], SysMemPitch = pitch}
			if !testing.expect(t, !failed(r.capture_device_11.CreateTexture2D(r.capture_device_11, &source_desc, &initial, &source))) do return
			defer com_release(source)
			if !testing.expect(t, !failed(MFCreateDXGISurfaceBuffer(d3d11.ITexture2D_UUID, cast(^win32.IUnknown)source, 0, false, &buffer))) do return
		} else if software_2d {
			fourcc := MFVideoFormat_NV12.Data1
			switch format {
			case .P010: fourcc = MFVideoFormat_P010.Data1
			case .YUY2: fourcc = MFVideoFormat_YUY2.Data1
			case .RGB24: fourcc = MFVideoFormat_ARGB32.Data1
			case .NV12, .I420, .MJPEG:
			}
			if !testing.expect(t, !failed(MFCreate2DMediaBuffer(u32(source_width), u32(source_height), fourcc, win32.BOOL(bottom_up), &buffer))) do return
			buffer_2d: ^IMF2DBuffer2
			if !testing.expect(t, !failed(buffer.QueryInterface(buffer, IID_IMF2DBuffer2, cast(^rawptr)&buffer_2d))) do return
			defer com_release(buffer_2d)
			scanline, buffer_start: ^u8
			stride: i32
			buffer_length: u32
			if !testing.expect(t, !failed(buffer_2d.Lock2DSize(buffer_2d, MF2DBuffer_LockFlags_Write, &scanline, &stride, &buffer_start, &buffer_length))) do return
			row_bytes, valid := capture_upload_pitch(format, u32(source_width), u32(source_height), 0, u32(length))
			if !testing.expect(t, valid) {
				buffer_2d.Unlock2D(buffer_2d)
				return
			}
			for row in 0..<length/int(row_bytes) {
				destination := mem.ptr_offset(scanline, row*int(stride))
				mem.copy_non_overlapping(destination, &pixels[row*int(row_bytes)], int(row_bytes))
			}
			buffer_2d.Unlock2D(buffer_2d)
			// Surface pitch must win over stale/default media-type metadata.
			r.capture_stride = 1
		} else {
			if !testing.expect(t, !failed(MFCreateMemoryBuffer(u32(length), &buffer))) do return
			data: ^u8
			if !testing.expect(t, !failed(buffer.Lock(buffer, &data, nil, nil))) do return
			mem.copy_non_overlapping(data, &pixels[0], length)
			buffer.Unlock(buffer)
			buffer.SetCurrentLength(buffer, u32(length))
		}
		sample: ^IMFSample
		if !testing.expect(t, !failed(MFCreateSample(&sample))) do return
		defer com_release(sample)
		if !testing.expect(t, !failed(sample.AddBuffer(sample, buffer))) do return
		capture_copy_sample(&r, sample)
		testing.expect_value(t, r.video_sequence, u64(1))
		testing.expect_value(t, r.video_vertical_flip, u32(1) if bottom_up else u32(0))
		r.capture_stride = 0
		capture_copy_sample(&r, sample)
		testing.expect_value(t, r.video_sequence, u64(1)) // Render still owns key 1.
		if !testing.expect(t, r.render_mutex.AcquireSync(r.render_mutex, 1, 1000) == 0) do return
		r.render_mutex.ReleaseSync(r.render_mutex, 1)
		display: ^d3d11.ITexture2D
		display_desc := d3d11.TEXTURE2D_DESC{
			Width = 32, Height = 18, MipLevels = 1, ArraySize = 1,
			Format = .B8G8R8A8_UNORM, SampleDesc = {Count = 1},
			Usage = .DEFAULT, BindFlags = {.RENDER_TARGET},
		}
		if !testing.expect(t, !failed(r.device_11.CreateTexture2D(r.device_11, &display_desc, nil, &display))) do return
		defer com_release(display)
		target: ^d3d11.IRenderTargetView
		if !testing.expect(t, !failed(r.device_11.CreateRenderTargetView(r.device_11, cast(^d3d11.IResource)display, nil, &target))) do return
		defer com_release(target)
		testing.expect_value(t, video_pipeline_draw(&r, target), u64(1))
		// A repaint must draw the same completed frame without another capture.
		testing.expect_value(t, video_pipeline_draw(&r, target), u64(1))
		staging: ^d3d11.ITexture2D
		desc := d3d11.TEXTURE2D_DESC{
			Width = 32, Height = 18, MipLevels = 1, ArraySize = 1,
			Format = .B8G8R8A8_UNORM, SampleDesc = {Count = 1},
			Usage = .STAGING, CPUAccessFlags = {.READ},
		}
		if !testing.expect(t, !failed(r.device_11.CreateTexture2D(r.device_11, &desc, nil, &staging))) do return
		defer com_release(staging)
		r.context_11.CopyResource(r.context_11, cast(^d3d11.IResource)staging, cast(^d3d11.IResource)display)
		mapped: d3d11.MAPPED_SUBRESOURCE
		if !testing.expect(t, !failed(r.context_11.Map(r.context_11, cast(^d3d11.IResource)staging, 0, .READ, {}, &mapped))) do return
		defer r.context_11.Unmap(r.context_11, cast(^d3d11.IResource)staging, 0)
		readback := cast([^]u8)mapped.pData
		for y in 0..<18 {
			for x in 0..<32 {
				index := y*int(mapped.RowPitch)+x*4
				for channel in 0..<3 {
					expected := (channel+1)*20+y if format == .RGB24 else 0
					if !testing.expect(t, abs(int(readback[index+channel])-expected) <= 1) do return
				}
			}
		}
	}
}
