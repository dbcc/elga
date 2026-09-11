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
	mutex:     sync.Mutex,
	flush_event: win32.HANDLE,
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
	context = runtime.default_context()
	callback := cast(^Source_Reader_Callback)this
	remaining := sync.atomic_sub_explicit(&callback.ref_count, 1, .Acq_Rel)-1
	if remaining == 0 {
		if callback.flush_event != nil do win32.CloseHandle(callback.flush_event)
		free(callback)
	}
	return win32.ULONG(remaining)
}

source_reader_on_read_sample :: proc "system" (this: ^IMFSourceReaderCallback, status: win32.HRESULT, stream, flags: u32, timestamp: i64, sample: ^IMFSample) -> win32.HRESULT {
	context = runtime.default_context()
	callback := cast(^Source_Reader_Callback)this
	sync.mutex_lock(&callback.mutex)
	defer sync.mutex_unlock(&callback.mutex)
	r := callback.renderer
	if r == nil || !sync.atomic_load_explicit(&r.capture_running, .Acquire) do return win32.HRESULT(win32.S_OK)
	if !failed(status) && sample != nil {
		capture_health_note_sample(&r.health)
		capture_copy_sample(r, sample)
	} else if failed(status) && sync.atomic_load_explicit(&r.capture_running, .Acquire) &&
	          sync.atomic_load_explicit(&r.edid_operation_active, .Acquire) == 0 {
		sync.atomic_add_explicit(&r.health.source_errors, 1, .Relaxed)
		capture_request_refresh(r)
	}
	if sync.atomic_load_explicit(&r.capture_running, .Acquire) &&
	   sync.atomic_load_explicit(&r.capture_refresh, .Acquire) == 0 &&
	   sync.atomic_load_explicit(&r.edid_operation_active, .Acquire) == 0 {
		read_hr := callback.reader.ReadSample(callback.reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nil, nil, nil, nil)
		if failed(read_hr) {
			sync.atomic_add_explicit(&r.health.source_errors, 1, .Relaxed)
			capture_request_refresh(r)
		}
	}
	return win32.HRESULT(win32.S_OK)
}

source_reader_on_flush :: proc "system" (this: ^IMFSourceReaderCallback, stream: u32) -> win32.HRESULT {
	callback := cast(^Source_Reader_Callback)this
	win32.SetEvent(callback.flush_event)
	return win32.HRESULT(win32.S_OK)
}

// Detach before releasing the reader or GPU resources. Late COM callbacks keep
// their own reference alive, but can no longer touch this capture session.
source_reader_detach :: proc(callback: ^Source_Reader_Callback) {
	sync.mutex_lock(&callback.mutex)
	defer sync.mutex_unlock(&callback.mutex)
	callback.renderer = nil
	callback.reader = nil
}

capture_wait_for_flush :: proc(r: ^Renderer, callback: ^Source_Reader_Callback) -> bool {
	handles := [2]win32.HANDLE{callback.flush_event, r.capture_event}
	for sync.atomic_load_explicit(&r.capture_running, .Acquire) {
		result := win32.WaitForMultipleObjects(2, &handles[0], false, win32.INFINITE)
		if result == win32.WAIT_OBJECT_0 do return true
		if result != win32.WAIT_OBJECT_0+1 do return false
	}
	return false
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
	if sync.atomic_exchange_explicit(&r.capture_refresh, 1, .Acq_Rel) == 0 {
		capture_health_note_recovery(&r.health)
	}
	if r.capture_event != nil do win32.SetEvent(r.capture_event)
}

capture_start :: proc(r: ^Renderer) -> bool {
	if r.capture_thread != nil do return true
	capture_health_reset_timing(r)
	sync.atomic_store_explicit(&r.capture_ready, 0, .Release)
	sync.atomic_store_explicit(&r.capture_refresh, 0, .Release)
	sync.atomic_store_explicit(&r.capture_mode_count, 0, .Release)
	sync.atomic_store_explicit(&r.source_mode_count, 0, .Release)
	sync.atomic_store_explicit(&r.capture_formats, 0, .Release)
	sync.atomic_store_explicit(&r.edid_request_kind, u32(EDID_Request_Kind.None), .Release)
	sync.atomic_store_explicit(&r.edid_operation_active, 0, .Release)
	sync.atomic_store_explicit(&r.edid_mode_known, 0, .Relaxed)
	sync.atomic_store_explicit(&r.edid_error, u32(EDID_Protocol_Error.None), .Relaxed)
	sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Reading), .Release)
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
			sync.atomic_add_explicit(&r.health.source_errors, 1, .Relaxed)
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

	callback := new(Source_Reader_Callback, runtime.default_context().allocator)
	callback^ = Source_Reader_Callback {
		vtable = &source_reader_callback_vtable,
		ref_count = 1,
		renderer = r,
	}
	defer com_release(callback)
	callback.flush_event = win32.CreateEventW(nil, false, false, nil)
	if callback.flush_event == nil do return
	reader, source, mode, edid_identity_verified, ok := capture_open_reader(r, cast(^IMFSourceReaderCallback)callback)
	defer com_release(source)
	defer {
		if source != nil do source.Shutdown(source)
	}
	defer com_release(reader)
	defer source_reader_detach(callback)
	if !ok {
		sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Unavailable), .Release)
		fmt.eprintln("Elgato 4K X capture initialization failed")
		return
	}
	edid_controller: EDID_Windows_Controller
	edid_available := false
	edid_current := EDID_Mode.Internal
	edid_error := EDID_Protocol_Error.Unsupported
	if edid_identity_verified {
		edid_controller, edid_current, edid_error, edid_available = edid_windows_open(source, r)
	}
	defer edid_windows_close(&edid_controller)
	edid_transport := edid_windows_transport(&edid_controller)
	if edid_available {
		if generation == sync.atomic_load_explicit(&r.capture_generation, .Acquire) {
			sync.atomic_store_explicit(&r.edid_error, u32(edid_error), .Relaxed)
			verification_required := sync.atomic_load_explicit(&r.edid_verification_required, .Acquire) != 0
			if edid_error == .None && !verification_required {
				sync.atomic_store_explicit(&r.edid_mode, u32(edid_current), .Relaxed)
				sync.atomic_store_explicit(&r.edid_mode_known, 1, .Relaxed)
				sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Ready), .Release)
				fmt.eprintf("EDID protocol verified: node=%d mode=%s\n", edid_controller.node_id, edid_mode_name(edid_current))
			} else if verification_required {
				sync.atomic_store_explicit(&r.edid_error, u32(EDID_Protocol_Error.Readback_Failed), .Relaxed)
				sync.atomic_store_explicit(&r.edid_mode_known, 0, .Relaxed)
				sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Unknown), .Release)
				fmt.eprintln("EDID write remains unverified; explicit refresh required")
			} else {
				sync.atomic_store_explicit(&r.edid_mode_known, 0, .Relaxed)
				sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Unavailable), .Release)
				fmt.eprintf("EDID protocol validation failed: %v\n", edid_error)
			}
		}
	} else {
		sync.atomic_store_explicit(&r.edid_error, u32(EDID_Protocol_Error.Unsupported), .Relaxed)
		sync.atomic_store_explicit(&r.edid_mode_known, 0, .Relaxed)
		sync.atomic_store_explicit(&r.edid_status, u32(EDID_Availability.Unavailable), .Release)
		fmt.eprintln("EDID extension unavailable on the selected capture source")
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
	win32.PostMessageW(r.hwnd, CAPTURE_READY_MESSAGE, win32.WPARAM(generation), 0)
	for sync.atomic_load_explicit(&r.capture_running, .Acquire) {
		if win32.WaitForSingleObject(r.capture_event, win32.INFINITE) != win32.WAIT_OBJECT_0 do break
		if !sync.atomic_load_explicit(&r.capture_running, .Acquire) do break
		request_kind := EDID_Request_Kind.None
		if sync.atomic_load_explicit(&r.edid_request_kind, .Acquire) != u32(EDID_Request_Kind.None) {
			// Publish active before removing the mailbox entry so the UI never
			// observes a false idle window between the two states.
			sync.atomic_store_explicit(&r.edid_operation_active, 1, .Release)
			request_kind = EDID_Request_Kind(sync.atomic_exchange_explicit(&r.edid_request_kind, u32(EDID_Request_Kind.None), .Acq_Rel))
		}
		if request_kind != .None {
			request_id := sync.atomic_load_explicit(&r.edid_request_id, .Acquire)
			request_generation := sync.atomic_load_explicit(&r.edid_request_generation, .Acquire)
			if request_generation != generation || !edid_available {
				sync.atomic_store_explicit(&r.edid_operation_active, 0, .Release)
				renderer_publish_edid_result(r, EDID_Result{
					request_id = request_id,
					generation = request_generation,
					error = .Unsupported,
				})
				continue
			}
			// Stop the callback chain, drain any callback already executing, then
			// cancel the one outstanding asynchronous read before touching KS.
			sync.mutex_lock(&callback.mutex)
			sync.mutex_unlock(&callback.mutex)
			flush_ok := !failed(reader.Flush(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM)) && capture_wait_for_flush(r, callback)
			result := EDID_Result{request_id = request_id, generation = generation}
			if !flush_ok {
				result.error = .Transfer_Failed
			} else if request_kind == .Refresh {
				result.mode, result.error = edid_read_mode(&edid_transport)
				result.mode_known = result.error == .None
			} else {
				requested := EDID_Mode(sync.atomic_load_explicit(&r.edid_requested_mode, .Acquire))
				result.mode, result.mode_known, result.disposition, result.error = edid_set_mode(&edid_transport, requested)
			}
			sync.atomic_store_explicit(&r.edid_operation_active, 0, .Release)
			renderer_publish_edid_result(r, result)
			if !edid_requires_reconnect(result.disposition) && sync.atomic_load_explicit(&r.capture_running, .Acquire) &&
			   sync.atomic_load_explicit(&r.capture_refresh, .Acquire) == 0 {
				hr = reader.ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nil, nil, nil, nil)
				if failed(hr) {
					sync.atomic_add_explicit(&r.health.source_errors, 1, .Relaxed)
					capture_request_refresh(r)
				}
			}
			continue
		}
		if sync.atomic_load_explicit(&r.capture_refresh, .Acquire) == 0 do continue
		// Drain any callback that could still be issuing ReadSample before Flush.
		sync.mutex_lock(&callback.mutex)
		sync.mutex_unlock(&callback.mutex)
		if failed(reader.Flush(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM)) do break
		if !capture_wait_for_flush(r, callback) do break
		// Back off a temporarily unavailable HDMI source, but wake on shutdown.
		win32.WaitForSingleObject(r.capture_event, 250)
		if sync.atomic_load_explicit(&r.capture_running, .Acquire) {
			sync.atomic_store_explicit(&r.capture_refresh, 0, .Release)
			hr = reader.ReadSample(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, 0, nil, nil, nil, nil)
			if failed(hr) {
				sync.atomic_add_explicit(&r.health.source_errors, 1, .Relaxed)
				capture_request_refresh(r)
			}
		}
	}
}

capture_open_reader :: proc(r: ^Renderer, callback: ^IMFSourceReaderCallback) -> (reader: ^IMFSourceReader, source: ^IMFMediaSource, selected_mode: Capture_Mode, edid_identity_verified: bool, ok: bool) {
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
			identity_matches := utf16_contains_ascii_case_insensitive(name, name_len, "4k x")
			device_supports_edid := false
			if identity_matches {
				symbolic_link: ^u16
				symbolic_link_len: u32
				if !failed(attributes.GetAllocatedString(attributes, &MF_DEVSOURCE_ATTRIBUTE_SOURCE_TYPE_VIDCAP_SYMBOLIC_LINK, &symbolic_link, &symbolic_link_len)) {
					device_supports_edid = utf16_contains_ascii_case_insensitive(symbolic_link, symbolic_link_len, "vid_0fd9") &&
						(utf16_contains_ascii_case_insensitive(symbolic_link, symbolic_link_len, "pid_009b") ||
						 utf16_contains_ascii_case_insensitive(symbolic_link, symbolic_link_len, "pid_009c"))
					win32.CoTaskMemFree(rawptr(symbolic_link))
				}
			}
			if activation == nil && identity_matches {
				activation = device
				edid_identity_verified = device_supports_edid
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
	// Audio is monitored separately through WASAPI. Unread selected streams can
	// otherwise accumulate samples inside the Media Foundation source.
	if failed(reader.SetStreamSelection(reader, MF_SOURCE_READER_ALL_STREAMS, false)) do return
	if failed(reader.SetStreamSelection(reader, MF_SOURCE_READER_FIRST_VIDEO_STREAM, true)) do return
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
		if mode.height == 0 || mode.fps_num == 0 || mode.fps_den == 0 || u64(mode.width)*9 != u64(mode.height)*16 do continue
		available |= u32(1) << u32(format)
		if source_count >= len(r.source_modes) do continue
		source_index := source_count
		r.source_modes[source_index] = mode
		source_count += 1
		if format != requested || count >= len(r.capture_mode_indices) do continue

		insert := count
		for insert > 0 && mode_better(mode, r.source_modes[int(r.capture_mode_indices[insert-1])], r.requested_width == 0) {
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
		if !found || mode_better(mode, best, width == 0) {
			best = mode
			found = true
		}
	}
	return best.format, found
}

capture_pick_best_mode_for_format :: proc(r: ^Renderer, format: Capture_Format, prefer_uhd_60 := false) -> (Capture_Mode, bool) {
	count := int(sync.atomic_load_explicit(&r.source_mode_count, .Acquire))
	best: Capture_Mode
	found := false
	for i in 0..<count {
		mode := r.source_modes[i]
		if mode.format != format do continue
		if !found || mode_better(mode, best, prefer_uhd_60) {
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

mode_better :: proc(a, b: Capture_Mode, prefer_uhd_60 := false) -> bool {
	a_pixels := u64(a.width)*u64(a.height)
	b_pixels := u64(b.width)*u64(b.height)
	if a_pixels != b_pixels do return a_pixels > b_pixels
	if prefer_uhd_60 && a.width >= 3840 && a.height >= 2160 {
		// The 4K X advertises high-rate USB capture modes independently of the
		// HDMI timing. Requesting 4K144 for a 4K60 input only makes the card emit
		// duplicate samples. Prefer the highest rate at or below 60 Hz. If no
		// such mode exists, use the lowest advertised rate rather than asking the
		// card to synthesize still more frames.
		a_at_most_60 := u64(a.fps_num) <= 60*u64(a.fps_den)
		b_at_most_60 := u64(b.fps_num) <= 60*u64(b.fps_den)
		if a_at_most_60 != b_at_most_60 do return a_at_most_60
		if !a_at_most_60 {
			return u64(a.fps_num)*u64(b.fps_den) < u64(b.fps_num)*u64(a.fps_den)
		}
	}
	return u64(a.fps_num)*u64(b.fps_den) > u64(b.fps_num)*u64(a.fps_den)
}

capture_copy_sample :: proc(r: ^Renderer, sample: ^IMFSample) {
	// Drop a busy frame before querying COM buffers or merging software samples.
	if !video_mutex_acquire(r.capture_mutex, 0) {
		sync.atomic_add_explicit(&r.health.busy_drops, 1, .Relaxed)
		return
	}
	ok := capture_upload_sample(r, sample) && capture_process_uploaded_frame(r)
	if ok {
		// Publish metadata while the matching texture is exclusively owned.
		sync.atomic_add_explicit(&r.video_sequence, 1, .Release)
	} else {
		sync.atomic_add_explicit(&r.health.upload_errors, 1, .Relaxed)
	}
	// Failed uploads/conversions leave the capture key available for a retry.
	r.capture_mutex.ReleaseSync(r.capture_mutex, 1 if ok else 0)
	if ok do renderer_request_redraw(r)
}

capture_upload_sample :: proc(r: ^Renderer, sample: ^IMFSample) -> bool {
	count: u32
	if failed(sample.GetBufferCount(sample, &count)) || count == 0 do return false
	buffer: ^IMFMediaBuffer
	if count == 1 {
		if failed(sample.GetBufferByIndex(sample, 0, &buffer)) do return false
	} else {
		if failed(sample.ConvertToContiguousBuffer(sample, &buffer)) do return false
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
			defer com_release(texture)
			desc: d3d11.TEXTURE2D_DESC
			texture.GetDesc(texture, &desc)
			if desc.MipLevels == 0 || u64(subresource) >= u64(desc.MipLevels)*u64(desc.ArraySize) do return false
			mip := subresource%desc.MipLevels
			if desc.Format != capture_format_dxgi(r.capture_format) ||
			   max(desc.Width>>mip, 1) < r.capture_width || max(desc.Height>>mip, 1) < r.capture_height {
				return false
			}
			// Decoder surfaces may include alignment padding beyond the image.
			box := d3d11.BOX{right = r.capture_width, bottom = r.capture_height, back = 1}
			destination := r.processed_texture if r.capture_format == .RGB24 else r.capture_texture
			r.capture_context_11.CopySubresourceRegion(r.capture_context_11, cast(^d3d11.IResource)destination, 0, 0, 0, 0, cast(^d3d11.IResource)texture, subresource, &box)
			sync.atomic_store_explicit(&r.video_vertical_flip, 0, .Release)
			return true
		}
		com_release(texture)
	}

	// Read 2D software surfaces in place. IMFMediaBuffer.Lock can allocate a
	// packed copy and copy it back on Unlock; a read-only 2D lock avoids that
	// work and supplies the actual surface pitch instead of media-type metadata.
	buffer_2d: ^IMF2DBuffer2
	if !failed(buffer.QueryInterface(buffer, IID_IMF2DBuffer2, cast(^rawptr)&buffer_2d)) {
		defer com_release(buffer_2d)
		scanline, buffer_start: ^u8
		stride: i32
		length: u32
		if !failed(buffer_2d.Lock2DSize(buffer_2d, MF2DBuffer_LockFlags_Read, &scanline, &stride, &buffer_start, &length)) {
			defer buffer_2d.Unlock2D(buffer_2d)
			data, pitch, valid := capture_upload_2d_data(r.capture_format, r.capture_width, r.capture_height, stride, scanline, buffer_start, length)
			if !valid do return false
			capture_upload_pixels(r, data, pitch, stride < 0)
			return true
		}
	}

	// Plain software buffers still use the contiguous fallback.
	data: ^u8
	max_length, current_length: u32
	if failed(buffer.Lock(buffer, &data, &max_length, &current_length)) do return false
	defer buffer.Unlock(buffer)
	if data == nil || current_length > max_length do return false
	pitch, valid := capture_upload_pitch(r.capture_format, r.capture_width, r.capture_height, r.capture_stride, current_length)
	if !valid do return false
	capture_upload_pixels(r, data, pitch, r.capture_stride < 0)
	return true
}

capture_upload_pixels :: proc(r: ^Renderer, data: ^u8, pitch: u32, bottom_up: bool) {
	destination := r.processed_texture if r.capture_format == .RGB24 else r.capture_texture
	// SrcDepthPitch is unused for these 2D textures.
	r.capture_context_11.UpdateSubresource(r.capture_context_11, cast(^d3d11.IResource)destination, 0, nil, rawptr(data), pitch, 0)
	flip := u32(1) if r.capture_format == .RGB24 && bottom_up else u32(0)
	sync.atomic_store_explicit(&r.video_vertical_flip, flip, .Release)
}

capture_upload_2d_data :: proc(format: Capture_Format, width, height: u32, stride: i32, scanline, buffer_start: ^u8, length: u32) -> (data: ^u8, pitch: u32, valid: bool) {
	if scanline == nil || buffer_start == nil || height == 0 || stride == 0 do return
	start_address := uintptr(buffer_start)
	scanline_address := uintptr(scanline)
	if scanline_address < start_address do return
	offset := u64(scanline_address-start_address)
	if offset > u64(length) do return
	if stride < 0 {
		// Lock2DSize returns the displayed top row, which is last in memory for
		// bottom-up RGB. Upload from the lowest row and let the shader flip it.
		preceding_rows := u64(abs(i64(stride)))*u64(height-1)
		if preceding_rows > offset do return
		offset -= preceding_rows
	}
	pitch, valid = capture_upload_pitch(format, width, height, stride, length-u32(offset))
	if valid do data = cast(^u8)(start_address+uintptr(offset))
	return
}

capture_process_uploaded_frame :: proc(r: ^Renderer) -> bool {
	if r.capture_format == .RGB24 do return true
	stream := d3d11.VIDEO_PROCESSOR_STREAM{Enable = true, pInputSurface = r.video_input_view}
	return !failed(r.video_context.VideoProcessorBlt(r.video_context, r.video_processor, r.video_output_view, 0, 1, &stream))
}

capture_upload_pitch :: proc(format: Capture_Format, width, height: u32, stride: i32, length: u32) -> (u32, bool) {
	if width == 0 || height == 0 do return 0, false
	planar := format == .NV12 || format == .P010 || format == .I420 || format == .MJPEG
	if planar && (width%2 != 0 || height%2 != 0 || stride < 0) do return 0, false
	if format == .YUY2 && (width%2 != 0 || stride < 0) do return 0, false
	row_bytes := u64(width)
	if format == .P010 || format == .YUY2 do row_bytes *= 2
	if format == .RGB24 do row_bytes *= 4
	pitch := u64(abs(i64(stride))) if stride != 0 else row_bytes
	rows := u64(height)
	if planar do rows += u64(height)/2
	// Only the final row's pixels must be readable; trailing padding need not
	// exist. Division avoids overflow for malformed dimensions and strides.
	if pitch < row_bytes || row_bytes > u64(length) do return 0, false
	if rows > 1 && pitch > (u64(length)-row_bytes)/(rows-1) do return 0, false
	return u32(pitch), true
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

utf16_equals_ascii_case_insensitive :: proc(text: ^u16, length: u32, expected: string) -> bool {
	if text == nil || int(length) != len(expected) do return false
	chars := cast([^]u16)text
	for i in 0..<len(expected) {
		actual := chars[i]
		if actual >= 'A' && actual <= 'Z' do actual += 'a'-'A'
		expected_char := u16(expected[i])
		if expected_char >= 'A' && expected_char <= 'Z' do expected_char += 'a'-'A'
		if actual != expected_char do return false
	}
	return true
}
