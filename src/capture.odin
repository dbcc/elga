package main

import "core:fmt"
import "base:runtime"
import "core:sync"
import "core:thread"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"

Capture_Mode :: struct {
	width:   u32,
	height:  u32,
	fps_num: u32,
	fps_den: u32,
	range:   Video_Range,
	format:  Capture_Format,
	yuv_matrix: u32,
	stride: i32,
	native_index: u32,
}

Capture_Format :: enum u8 {
	NV12,
	P010,
	YUY2,
	I420,
	RGB24,
	MJPEG,
}

CAPTURE_FORMAT_COUNT     :: 6
GPU_CAPTURE_FORMAT_COUNT :: 3

Source_Reader_Callback :: struct {
	using vtable: ^IMFSourceReaderCallback_VTable,
	ref_count: u32,
	renderer:  ^Renderer,
	reader:    ^IMFSourceReader,
}

source_reader_callback_vtable := IMFSourceReaderCallback_VTable {
	unknown_vtable = win32.IUnknown_VTable {
		QueryInterface = source_reader_query_interface,
		AddRef = source_reader_add_ref,
		Release = source_reader_release,
	},
	OnReadSample = source_reader_on_read_sample,
	OnFlush = source_reader_on_flush,
	OnEvent = source_reader_on_event,
}

source_reader_query_interface :: proc "system" (this: ^win32.IUnknown, iid: win32.REFIID, object: ^rawptr) -> win32.HRESULT {
	if object == nil || iid == nil do return win32.HRESULT(-2147467262)
	if iid^ != IID_IUnknown_Value && iid^ != IID_IMFSourceReaderCallback_Value {
		object^ = nil
		return win32.HRESULT(-2147467262)
	}
	object^ = rawptr(this)
	source_reader_add_ref(this)
	return win32.HRESULT(win32.S_OK)
}

source_reader_add_ref :: proc "system" (this: ^win32.IUnknown) -> win32.ULONG {
	callback := cast(^Source_Reader_Callback)this
	return win32.ULONG(sync.atomic_add_explicit(&callback.ref_count, 1, .Relaxed)+1)
}

source_reader_release :: proc "system" (this: ^win32.IUnknown) -> win32.ULONG {
	callback := cast(^Source_Reader_Callback)this
	return win32.ULONG(sync.atomic_sub_explicit(&callback.ref_count, 1, .Release)-1)
}

source_reader_on_read_sample :: proc "system" (this: ^IMFSourceReaderCallback, status: win32.HRESULT, stream, flags: u32, timestamp: i64, sample: ^IMFSample) -> win32.HRESULT {
	context = runtime.default_context()
	callback := cast(^Source_Reader_Callback)this
	r := callback.renderer
	if !failed(status) && sample != nil {
		capture_copy_sample(r, sample)
	} else if failed(status) && sync.atomic_load_explicit(&r.capture_running, .Acquire) {
		capture_request_refresh(r)
	}
	if sync.atomic_load_explicit(&r.capture_running, .Acquire) &&
	   sync.atomic_load_explicit(&r.capture_refresh, .Acquire) == 0 {
		read_hr := callback.reader.ReadSample(callback.reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nil, nil, nil, nil)
		if failed(read_hr) do capture_request_refresh(r)
	}
	return win32.HRESULT(win32.S_OK)
}

source_reader_on_flush :: proc "system" (this: ^IMFSourceReaderCallback, stream: u32) -> win32.HRESULT {
	return win32.HRESULT(win32.S_OK)
}

source_reader_on_event :: proc "system" (this: ^IMFSourceReaderCallback, stream: u32, event: rawptr) -> win32.HRESULT {
	return win32.HRESULT(win32.S_OK)
}

Video_Range :: enum u8 {
	Unknown,
	Full,
	Limited,
}

capture_request_refresh :: proc(r: ^Renderer) {
	sync.atomic_store_explicit(&r.capture_refresh, 1, .Release)
	if r.capture_event != nil do win32.SetEvent(r.capture_event)
}

capture_start :: proc(r: ^Renderer) -> bool {
	if r.capture_thread != nil do return true
	sync.atomic_store_explicit(&r.capture_ready, 0, .Release)
	sync.atomic_store_explicit(&r.capture_refresh, 0, .Release)
	r.capture_event = win32.CreateEventW(nil, false, false, nil)
	if r.capture_event == nil {
		fmt.eprintln("Capture control event creation failed")
		return false
	}
	sync.atomic_store_explicit(&r.capture_running, true, .Release)
	sync.atomic_add_explicit(&r.capture_generation, 1, .Acq_Rel)
	r.capture_thread = thread.create(capture_thread_proc, .High, "elgato-mf")
	if r.capture_thread == nil {
		sync.atomic_store_explicit(&r.capture_running, false, .Release)
		win32.CloseHandle(r.capture_event)
		r.capture_event = nil
		fmt.eprintln("Capture thread creation failed")
		return false
	}
	r.capture_thread.data = r
	thread.start(r.capture_thread)
	return true
}

capture_stop :: proc(r: ^Renderer) {
	if r.capture_thread == nil {
		sync.atomic_store_explicit(&r.capture_ready, 0, .Release)
		if r.capture_event != nil {
			win32.CloseHandle(r.capture_event)
			r.capture_event = nil
		}
		return
	}
	sync.atomic_store_explicit(&r.capture_running, false, .Release)
	win32.SetEvent(r.capture_event)
	thread.join(r.capture_thread)
	thread.destroy(r.capture_thread)
	r.capture_thread = nil
	win32.CloseHandle(r.capture_event)
	r.capture_event = nil
	sync.atomic_store_explicit(&r.capture_ready, 0, .Release)
}

capture_thread_proc :: proc(t: ^thread.Thread) {
	r := cast(^Renderer)t.data
	if r == nil do return
	generation := sync.atomic_load_explicit(&r.capture_generation, .Acquire)
	defer {
		unexpected_stop := sync.atomic_load_explicit(&r.capture_running, .Acquire)
		sync.atomic_store_explicit(&r.capture_ready, 0, .Release)
		sync.atomic_store_explicit(&r.capture_running, false, .Release)
		if unexpected_stop {
			win32.PostMessageW(r.hwnd, CAPTURE_FAILED_MESSAGE, win32.WPARAM(generation), 0)
		}
	}
	hr := win32.CoInitializeEx(nil, .MULTITHREADED)
	if failed(hr) {
		fmt.eprintf("COM initialization failed: 0x%08x\n", u32(hr))
		return
	}
	defer win32.CoUninitialize()
	if failed(MFStartup(MF_VERSION, MFSTARTUP_FULL)) {
		fmt.eprintln("Media Foundation startup failed")
		return
	}
	defer MFShutdown()

	callback := Source_Reader_Callback {
		vtable = &source_reader_callback_vtable,
		ref_count = 1,
		renderer = r,
	}
	reader, source, mode, ok := capture_open_reader(r, cast(^IMFSourceReaderCallback)&callback)
	defer com_release(source)
	defer {
		if source != nil do source.Shutdown(source)
	}
	defer com_release(reader)
	if !ok {
		fmt.eprintln("Elgato 4K X capture initialization failed")
		return
	}
	if mode.width != r.resource_width || mode.height != r.resource_height {
		fmt.eprintf("Capture/resource size mismatch: %dx%d vs %dx%d\n", mode.width, mode.height, r.resource_width, r.resource_height)
		return
	}
	r.capture_width = mode.width
	r.capture_height = mode.height
	r.capture_fps_num = mode.fps_num
	r.capture_fps_den = mode.fps_den
	r.capture_matrix = mode.yuv_matrix
	r.capture_range = mode.range
	r.capture_stride = mode.stride
	video_processor_set_color(r)
	callback.reader = reader
	sync.atomic_store_explicit(&r.capture_ready, 1, .Release)
	path := capture_format_pipeline_name(mode.format)
	presentation := "D3D11 copy" if mode.format == .RGB24 else "D3D11 video processor"
		fmt.eprintf("Capture ready: %dx%d @ %.3f FPS, %s, %s range (%s -> %s -> D3D11)\n", mode.width, mode.height, f64(mode.fps_num)/f64(mode.fps_den), capture_format_name(mode.format), video_range_name(mode.range), path, presentation)
	fmt.eprintf("Color metadata: matrix=%d\n", mode.yuv_matrix)
	hr = reader.ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nil, nil, nil, nil)
	if failed(hr) {
		fmt.eprintf("Media Foundation asynchronous ReadSample failed: 0x%08x\n", u32(hr))
		return
	}
	for sync.atomic_load_explicit(&r.capture_running, .Acquire) {
		if win32.WaitForSingleObject(r.capture_event, win32.INFINITE) != win32.WAIT_OBJECT_0 do break
		if !sync.atomic_load_explicit(&r.capture_running, .Acquire) do break
		if sync.atomic_exchange_explicit(&r.capture_refresh, 0, .Acq_Rel) == 0 do continue
		reader.Flush(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM)
		// The 4K X briefly rebuilds its HDMI pipeline after a range change.
		win32.Sleep(250)
		if sync.atomic_load_explicit(&r.capture_running, .Acquire) {
			hr = reader.ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nil, nil, nil, nil)
			if failed(hr) do capture_request_refresh(r)
		}
	}
	reader.Flush(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM)
}

capture_open_reader :: proc(r: ^Renderer, callback: ^IMFSourceReaderCallback) -> (reader: ^IMFSourceReader, source: ^IMFMediaSource, selected_mode: Capture_Mode, ok: bool) {
	enum_attributes: ^IMFAttributes
	if failed(MFCreateAttributes(&enum_attributes, 1)) do return
	defer com_release(enum_attributes)
	if failed(enum_attributes.SetGUID(enum_attributes, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_GUID)) do return

	devices: ^^IMFActivate
	device_count: u32
	if failed(MFEnumDeviceSources(enum_attributes, &devices, &device_count)) do return
	defer win32.CoTaskMemFree(rawptr(devices))

	activation: ^IMFActivate
	device_array := cast([^]^IMFActivate)devices
	for i in 0..<device_count {
		device := device_array[i]
		name: ^u16
		name_len: u32
		attributes := cast(^IMFAttributes)device
		if !failed(attributes.GetAllocatedString(attributes, &MF_DEVSOURCE_ATTRIBUTE_FRIENDLY_NAME, &name, &name_len)) {
			if activation == nil && utf16_contains_ascii_case_insensitive(name, name_len, "elgato 4k x") {
				activation = device
			} else {
				com_release(device)
			}
			win32.CoTaskMemFree(rawptr(name))
		} else {
			com_release(device)
		}
	}
	if activation == nil do return
	defer com_release(activation)

	if failed(activation.ActivateObject(activation, IID_IMFMediaSource, cast(^rawptr)&source)) do return

	token: u32
	manager: ^IMFDXGIDeviceManager
	if failed(MFCreateDXGIDeviceManager(&token, &manager)) do return
	defer com_release(manager)
	if failed(manager.ResetDevice(manager, cast(^win32.IUnknown)r.capture_device_11, token)) do return

	reader_attributes: ^IMFAttributes
	if failed(MFCreateAttributes(&reader_attributes, 5)) do return
	defer com_release(reader_attributes)
	if failed(reader_attributes.SetUnknown(reader_attributes, &MF_SOURCE_READER_D3D_MANAGER, cast(^win32.IUnknown)manager)) do return
	if failed(reader_attributes.SetUnknown(reader_attributes, &MF_SOURCE_READER_ASYNC_CALLBACK, cast(^win32.IUnknown)callback)) do return
	reader_attributes.SetUINT32(reader_attributes, &MF_LOW_LATENCY, 1)
	reader_attributes.SetUINT32(reader_attributes, &MF_READWRITE_ENABLE_HARDWARE_TRANSFORMS, 1)
	reader_attributes.SetUINT32(reader_attributes, &MF_SOURCE_READER_ENABLE_ADVANCED_VIDEO_PROCESSING, 1)
	if failed(MFCreateSourceReaderFromMediaSource(source, reader_attributes, &reader)) do return
	reader_ex: ^IMFSourceReaderEx
	if failed(reader.QueryInterface(reader, IID_IMFSourceReaderEx, cast(^rawptr)&reader_ex)) do return
	defer com_release(reader_ex)
	mode_count := capture_enumerate_modes(reader, r.capture_format, r)
	for i in 0..<mode_count {
		mode := capture_mode_at(r, i)
		if r.requested_width != 0 && (mode.width != r.requested_width || mode.height != r.requested_height) do continue
		native_type: ^IMFMediaType
		if failed(reader.GetNativeMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, mode.native_index, &native_type)) do continue
		stream_flags: u32
		hr := reader_ex.SetNativeMediaType(reader_ex, MF_SOURCE_READER_FIRST_VIDEO_STREAM, native_type, &stream_flags)
		com_release(native_type)
		if !failed(hr) && !capture_format_is_gpu(mode.format) {
			// First select the exact native source mode above, then insert the
			// smallest Windows transform needed by the GPU presentation path.
			converted: ^IMFMediaType
			if failed(MFCreateMediaType(&converted)) do continue
			converted_attributes := cast(^IMFAttributes)converted
			output_subtype := &MFVideoFormat_ARGB32 if mode.format == .RGB24 else &MFVideoFormat_NV12
			configured :=
				!failed(converted_attributes.SetGUID(converted_attributes, &MF_MT_MAJOR_TYPE, &MFMediaType_Video)) &&
				!failed(converted_attributes.SetGUID(converted_attributes, &MF_MT_SUBTYPE, output_subtype)) &&
				!failed(converted_attributes.SetUINT64(converted_attributes, &MF_MT_FRAME_SIZE, u64(mode.width)<<32 | u64(mode.height))) &&
				!failed(converted_attributes.SetUINT64(converted_attributes, &MF_MT_FRAME_RATE, u64(mode.fps_num)<<32 | u64(mode.fps_den)))
			if configured {
				hr = reader.SetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, nil, converted)
			} else {
				hr = transmute(win32.HRESULT)u32(win32.E_FAIL)
			}
			com_release(converted)
		}
		if !failed(hr) {
			selected_mode = mode
			capture_read_current_metadata(reader, &selected_mode)
			ok = true
			return
		}
	}
	return
}

capture_enumerate_modes :: proc(reader: ^IMFSourceReader, requested: Capture_Format, r: ^Renderer) -> int {
	count := 0
	source_count := 0
	available: u32
	sync.atomic_store_explicit(&r.capture_mode_count, 0, .Relaxed)
	sync.atomic_store_explicit(&r.source_mode_count, 0, .Relaxed)
	for index: u32 = 0; index < 1024; index += 1 {
		media_type: ^IMFMediaType
		if failed(reader.GetNativeMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, index, &media_type)) do break
		attributes := cast(^IMFAttributes)media_type
		major: win32.GUID
		subtype: win32.GUID
		size, rate: u64
		valid := !failed(attributes.GetGUID(attributes, &MF_MT_MAJOR_TYPE, &major)) && major == MFMediaType_Video &&
			!failed(attributes.GetGUID(attributes, &MF_MT_SUBTYPE, &subtype)) &&
			!failed(attributes.GetUINT64(attributes, &MF_MT_FRAME_SIZE, &size)) &&
			!failed(attributes.GetUINT64(attributes, &MF_MT_FRAME_RATE, &rate))
		com_release(media_type)
		if !valid do continue
		format, known := capture_format_from_guid(subtype)
		if !known do continue
		mode := Capture_Mode {
			width = u32(size>>32), height = u32(size),
			fps_num = u32(rate>>32), fps_den = u32(rate),
			format = format,
			native_index = index,
		}
		if mode.height == 0 || mode.fps_num == 0 || mode.fps_den == 0 || mode.width*9 != mode.height*16 do continue
		available |= u32(1) << u32(format)
		if source_count >= len(r.source_modes) do continue
		source_index := source_count
		r.source_modes[source_index] = mode
		source_count += 1
		if format != requested || count >= len(r.capture_mode_indices) do continue

		insert := count
		for insert > 0 && mode_better(mode, r.source_modes[int(r.capture_mode_indices[insert-1])]) {
			r.capture_mode_indices[insert] = r.capture_mode_indices[insert-1]
			insert -= 1
		}
		r.capture_mode_indices[insert] = u16(source_index)
		count += 1
	}
	sync.atomic_store_explicit(&r.source_mode_count, u32(source_count), .Release)
	sync.atomic_store_explicit(&r.capture_mode_count, u32(count), .Release)
	sync.atomic_store_explicit(&r.capture_formats, available, .Release)
	return count
}

capture_mode_at :: proc(r: ^Renderer, index: int) -> Capture_Mode {
	return r.source_modes[int(r.capture_mode_indices[index])]
}

capture_format_from_guid :: proc(subtype: win32.GUID) -> (Capture_Format, bool) {
	switch subtype {
	case MFVideoFormat_NV12: return .NV12, true
	case MFVideoFormat_P010: return .P010, true
	case MFVideoFormat_YUY2: return .YUY2, true
	case MFVideoFormat_I420: return .I420, true
	case MFVideoFormat_RGB24: return .RGB24, true
	case MFVideoFormat_MJPG: return .MJPEG, true
	}
	return .NV12, false
}

capture_format_guid :: proc(format: Capture_Format) -> ^win32.GUID {
	switch format {
	case .NV12: return &MFVideoFormat_NV12
	case .P010: return &MFVideoFormat_P010
	case .YUY2: return &MFVideoFormat_YUY2
	case .I420: return &MFVideoFormat_I420
	case .RGB24: return &MFVideoFormat_RGB24
	case .MJPEG: return &MFVideoFormat_MJPG
	}
	return &MFVideoFormat_NV12
}

capture_format_name :: proc(format: Capture_Format) -> cstring {
	switch format {
	case .NV12: return "NV12"
	case .P010: return "P010"
	case .YUY2: return "YUY2"
	case .I420: return "I420"
	case .RGB24: return "RGB24"
	case .MJPEG: return "MJPEG"
	}
	return "Unknown"
}

capture_format_menu_label :: proc(format: Capture_Format) -> cstring {
	switch format {
	case .NV12: return "NV12 - 8-bit 4:2:0"
	case .P010: return "P010 - 10-bit 4:2:0"
	case .YUY2: return "YUY2 - 8-bit 4:2:2"
	case .I420: return "I420 - converted to NV12"
	case .RGB24: return "RGB24 - expanded to 32-bit RGB"
	case .MJPEG: return "MJPEG - decoded to NV12"
	}
	return "Unknown"
}

capture_format_pipeline_name :: proc(format: Capture_Format) -> string {
	switch format {
	case .NV12, .P010, .YUY2: return "native GPU"
	case .RGB24: return "Media Foundation -> 32-bit RGB"
	case .I420, .MJPEG: return "Media Foundation -> NV12"
	}
	return "unknown"
}

capture_format_is_gpu :: proc(format: Capture_Format) -> bool {
	return int(format) < GPU_CAPTURE_FORMAT_COUNT
}

capture_format_available :: proc(r: ^Renderer, format: Capture_Format) -> bool {
	available := sync.atomic_load_explicit(&r.capture_formats, .Acquire)
	return available & (u32(1) << u32(format)) != 0
}

capture_resolution_available :: proc(r: ^Renderer, width, height: u32) -> bool {
	count := int(sync.atomic_load_explicit(&r.capture_mode_count, .Acquire))
	for i in 0..<count {
		mode := capture_mode_at(r, i)
		if mode.width == width && mode.height == height do return true
	}
	return false
}

capture_resolution_available_for_format :: proc(r: ^Renderer, format: Capture_Format, width, height: u32) -> bool {
	count := int(sync.atomic_load_explicit(&r.source_mode_count, .Acquire))
	for i in 0..<count {
		mode := r.source_modes[i]
		if mode.format == format && mode.width == width && mode.height == height do return true
	}
	return false
}

capture_pick_auto_format :: proc(r: ^Renderer, width, height: u32) -> (Capture_Format, bool) {
	count := int(sync.atomic_load_explicit(&r.source_mode_count, .Acquire))
	best: Capture_Mode
	found := false
	for i in 0..<count {
		mode := r.source_modes[i]
		if !capture_format_is_gpu(mode.format) do continue
		if width != 0 && (mode.width != width || mode.height != height) do continue
		if !found || mode_better(mode, best) {
			best = mode
			found = true
		}
	}
	return best.format, found
}

capture_pick_best_mode_for_format :: proc(r: ^Renderer, format: Capture_Format) -> (Capture_Mode, bool) {
	count := int(sync.atomic_load_explicit(&r.source_mode_count, .Acquire))
	best: Capture_Mode
	found := false
	for i in 0..<count {
		mode := r.source_modes[i]
		if mode.format != format do continue
		if !found || mode_better(mode, best) {
			best = mode
			found = true
		}
	}
	return best, found
}

capture_read_current_metadata :: proc(reader: ^IMFSourceReader, mode: ^Capture_Mode) {
	media_type: ^IMFMediaType
	if failed(reader.GetCurrentMediaType(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, &media_type)) do return
	defer com_release(media_type)
	nominal_range: u32
	yuv_matrix: u32
	attributes := cast(^IMFAttributes)media_type
	if !failed(attributes.GetUINT32(attributes, &MF_MT_VIDEO_NOMINAL_RANGE, &nominal_range)) {
		mode.range = video_range_from_mf(nominal_range)
	}
	if !failed(attributes.GetUINT32(attributes, &MF_MT_YUV_MATRIX, &yuv_matrix)) do mode.yuv_matrix = yuv_matrix
	stride: u32
	if !failed(attributes.GetUINT32(attributes, &MF_MT_DEFAULT_STRIDE, &stride)) do mode.stride = i32(stride)
}

video_range_from_mf :: proc(value: u32) -> Video_Range {
	switch value {
	case 1: return .Full
	case 2: return .Limited
	}
	return .Unknown
}

video_range_name :: proc(video_range: Video_Range) -> string {
	switch video_range {
	case .Full: return "full"
	case .Limited: return "limited"
	case .Unknown: return "unknown (limited fallback)"
	}
	return "unknown"
}

mode_better :: proc(a, b: Capture_Mode) -> bool {
	a_pixels := u64(a.width)*u64(a.height)
	b_pixels := u64(b.width)*u64(b.height)
	if a_pixels != b_pixels do return a_pixels > b_pixels
	return u64(a.fps_num)*u64(b.fps_den) > u64(b.fps_num)*u64(a.fps_den)
}

capture_copy_sample :: proc(r: ^Renderer, sample: ^IMFSample) {
	count: u32
	if failed(sample.GetBufferCount(sample, &count)) || count == 0 do return
	buffer: ^IMFMediaBuffer
	if count == 1 {
		if failed(sample.GetBufferByIndex(sample, 0, &buffer)) do return
	} else {
		if failed(sample.ConvertToContiguousBuffer(sample, &buffer)) do return
	}
	defer com_release(buffer)

	dxgi_buffer: ^IMFDXGIBuffer
	hr := buffer.QueryInterface(buffer, IID_IMFDXGIBuffer, cast(^rawptr)&dxgi_buffer)
	if !failed(hr) {
		texture: ^d3d11.ITexture2D
		subresource: u32
		hr = dxgi_buffer.GetResource(dxgi_buffer, d3d11.ITexture2D_UUID, cast(^rawptr)&texture)
		if !failed(hr) do hr = dxgi_buffer.GetSubresourceIndex(dxgi_buffer, &subresource)
		com_release(dxgi_buffer)
		if !failed(hr) && texture != nil {
			if failed(r.capture_mutex.AcquireSync(r.capture_mutex, 0, 0)) {
				com_release(texture)
				return
			}
			if r.capture_format == .RGB24 {
				r.capture_context_11.CopySubresourceRegion(r.capture_context_11, cast(^d3d11.IResource)r.processed_texture, 0, 0, 0, 0, cast(^d3d11.IResource)texture, subresource, nil)
			} else {
				r.capture_context_11.CopySubresourceRegion(r.capture_context_11, cast(^d3d11.IResource)r.capture_texture, 0, 0, 0, 0, cast(^d3d11.IResource)texture, subresource, nil)
			}
			sync.atomic_store_explicit(&r.video_vertical_flip, 0, .Release)
			ok := capture_process_uploaded_frame(r)
			com_release(texture)
			if ok do capture_publish_frame(r)
			return
		}
		com_release(texture)
	}

	// Software transforms can return a normal IMFMediaBuffer even with a D3D
	// manager configured. Upload that converted surface to the same default
	// texture used by the zero-copy path.
	data: ^u8
	max_length, current_length: u32
	if failed(buffer.Lock(buffer, &data, &max_length, &current_length)) || data == nil do return
	defer buffer.Unlock(buffer)
	output_format := r.capture_format if capture_format_is_gpu(r.capture_format) else Capture_Format.NV12
	default_pitch := r.capture_width
	if output_format == .P010 || output_format == .YUY2 do default_pitch *= 2
	if r.capture_format == .RGB24 do default_pitch *= 4
	pitch := u32(abs(r.capture_stride)) if r.capture_stride != 0 else default_pitch
	minimum_length := u64(pitch)*u64(r.capture_height)
	if r.capture_format != .RGB24 && (output_format == .NV12 || output_format == .P010) do minimum_length = minimum_length*3/2
	if pitch < default_pitch || u64(current_length) < minimum_length do return
	if failed(r.capture_mutex.AcquireSync(r.capture_mutex, 0, 0)) do return
	destination := r.processed_texture if r.capture_format == .RGB24 else r.capture_texture
	r.capture_context_11.UpdateSubresource(r.capture_context_11, cast(^d3d11.IResource)destination, 0, nil, rawptr(data), pitch, current_length)
	flip := u32(1) if r.capture_format == .RGB24 && r.capture_stride < 0 else u32(0)
	sync.atomic_store_explicit(&r.video_vertical_flip, flip, .Release)
	if capture_process_uploaded_frame(r) {
		capture_publish_frame(r)
	}
	return
}

capture_process_uploaded_frame :: proc(r: ^Renderer) -> bool {
	if r.capture_format == .RGB24 {
		r.capture_mutex.ReleaseSync(r.capture_mutex, 1)
		return true
	}
	stream := d3d11.VIDEO_PROCESSOR_STREAM{Enable = true, pInputSurface = r.video_input_view}
	hr := r.video_context.VideoProcessorBlt(r.video_context, r.video_processor, r.video_output_view, 0, 1, &stream)
	r.capture_mutex.ReleaseSync(r.capture_mutex, 1)
	return !failed(hr)
}

capture_publish_frame :: proc(r: ^Renderer) {
	sync.atomic_add_explicit(&r.video_sequence, 1, .Release)
	// Keep the renderer on the window thread and allow at most one queued
	// wake-up. Custom messages are serviced by the modal move/resize loop,
	// unlike an external event loop that Windows pauses while dragging.
	renderer_request_redraw(r)
}

utf16_contains_ascii_case_insensitive :: proc(text: ^u16, length: u32, needle: string) -> bool {
	if text == nil || int(length) < len(needle) do return false
	chars := cast([^]u16)text
	for start in 0..=int(length)-len(needle) {
		matches := true
		for j in 0..<len(needle) {
			c := chars[start+j]
			if c >= 'A' && c <= 'Z' do c += 'a'-'A'
			if c != u16(needle[j]) {
				matches = false
				break
			}
		}
		if matches do return true
	}
	return false
}
