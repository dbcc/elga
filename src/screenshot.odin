package main

import "base:runtime"
import "core:c"
import "core:fmt"
import "core:mem"
import "core:sync"
import "core:thread"
import "core:time"
import win32 "core:sys/windows"
import d3d11 "vendor:directx/d3d11"
import dxgi "vendor:directx/dxgi"
import stbi "vendor:stb/image"

Screenshot_Status :: enum {
	Idle,
	Waiting,
	Reading,
	Saving,
	Saved,
	Failed,
	Unavailable,
}

Screenshot_Error :: enum {
	None,
	Capture_Unavailable,
	Capture_Changed,
	Readback_Timeout,
	GPU,
	Memory,
	Thread,
	Folder,
	File,
	Encoding,
	Cancelled,
}

Screenshot_State :: struct {
	// Status and last_path are owned by the window thread. The worker only
	// touches its private job; join publishes that result before it is read.
	status: Screenshot_Status,
	error: Screenshot_Error,
	last_path: string,
	requested_at: time.Time,
	capture_generation: u32,
	staging: ^d3d11.ITexture2D,
	context_11: ^d3d11.IDeviceContext,
	width, height: u32,
	vertical_flip: bool,
	mapped: bool,
	worker: ^thread.Thread,
	job: ^Screenshot_Job,
}

Screenshot_Job :: struct {
	// The mapped texture stays alive until this worker finishes. Only the UI
	// thread calls D3D; reading its mapped CPU memory needs no device calls.
	source: [^]u8,
	row_pitch, width, height: u32,
	vertical_flip: bool,
	cancel_requested: u32,
	path: string,
	error: Screenshot_Error,
	file: win32.HANDLE,
	write_ok: bool,
}

SCREENSHOT_READBACK_TIMEOUT :: 3*time.Second

screenshot_busy :: proc(s: ^Screenshot_State) -> bool {
	return s.status == .Waiting || s.status == .Reading || s.status == .Saving
}

screenshot_status_text :: proc(s: ^Screenshot_State) -> string {
	switch s.status {
	case .Idle: return "Save capture frame as PNG (F8)"
	case .Waiting, .Reading, .Saving: return "Saving screenshot..."
	case .Saved: return "Screenshot saved"
	case .Unavailable: return "No capture frame available"
	case .Failed:
		#partial switch s.error {
		case .Capture_Changed: return "Capture changed; try screenshot again"
		case .Readback_Timeout: return "Screenshot timed out; try again"
		case .Folder: return "Could not create screenshot folder"
		case .File: return "Could not write screenshot file"
		case: return "Could not save screenshot"
		}
	}
	return ""
}

// Called on the window thread. A held key or repeated clicks cannot queue
// unbounded full-resolution textures or background encoders.
screenshot_request :: proc(s: ^Screenshot_State, r: ^Renderer) -> bool {
	if screenshot_busy(s) do return false
	if r != nil && r.drawing do return false
	s.error = .None
	if r == nil || !r.ready || r.capture_suspended || r.reconnect_thread != nil || r.video_texture == nil ||
	   sync.atomic_load_explicit(&r.capture_ready, .Acquire) == 0 ||
	   sync.atomic_load_explicit(&r.video_sequence, .Acquire) == 0 {
		s.status, s.error = .Unavailable, .Capture_Unavailable
		return false
	}
	s.capture_generation = sync.atomic_load_explicit(&r.capture_generation, .Acquire)
	s.requested_at = time.now()
	s.status = .Waiting
	return true
}

screenshot_release_readback :: proc(s: ^Screenshot_State) {
	if s.mapped {
		s.context_11.Unmap(s.context_11, cast(^d3d11.IResource)s.staging, 0)
		s.mapped = false
	}
	com_release(s.staging)
	com_release(s.context_11)
	s.staging, s.context_11 = nil, nil
}

screenshot_fail :: proc(s: ^Screenshot_State, error: Screenshot_Error) -> bool {
	screenshot_release_readback(s)
	s.status, s.error = .Failed, error
	return true
}

// Poll from the existing UI timer. Both shared-texture acquisition and Map
// are nonblocking; PNG compression and all filesystem work run on the worker.
screenshot_update :: proc(s: ^Screenshot_State, r: ^Renderer) -> bool {
	// Present may dispatch timers recursively. Never touch the render context
	// while its outer draw is in progress, even to retire a finished readback.
	if r != nil && r.drawing do return false
	if s.status == .Saving {
		if !thread.is_done(s.worker) || win32.WaitForSingleObject(s.worker.win32_thread, 0) != win32.WAIT_OBJECT_0 do return false
		thread.join(s.worker)
		thread.destroy(s.worker)
		s.worker = nil
		screenshot_release_readback(s)
		s.error = s.job.error
		s.status = .Saved if s.error == .None else .Failed
		if s.status == .Saved {
			delete(s.last_path, runtime.heap_allocator())
			s.last_path = s.job.path
			s.job.path = ""
		}
		screenshot_free_job(s)
		return true
	}
	if s.status != .Waiting && s.status != .Reading do return false
	if r == nil || !r.ready || r.capture_suspended || r.reconnect_thread != nil ||
	   sync.atomic_load_explicit(&r.capture_ready, .Acquire) == 0 ||
	   s.capture_generation != sync.atomic_load_explicit(&r.capture_generation, .Acquire) {
		return screenshot_fail(s, .Capture_Changed)
	}
	if time.since(s.requested_at) >= SCREENSHOT_READBACK_TIMEOUT {
		return screenshot_fail(s, .Readback_Timeout)
	}
	if s.status == .Waiting {
		if r.video_texture == nil || r.render_mutex == nil || r.device_11 == nil || r.context_11 == nil {
			return screenshot_fail(s, .Capture_Changed)
		}
		// Allocate once, before taking the shared capture lock. It is a private
		// texture: UI chrome, letterboxing and display scaling never enter it.
		if s.staging == nil {
			desc: d3d11.TEXTURE2D_DESC
			r.video_texture.GetDesc(r.video_texture, &desc)
			if desc.Format != .B8G8R8A8_UNORM || !screenshot_dimensions_valid(desc.Width, desc.Height) {
				return screenshot_fail(s, .GPU)
			}
			s.width, s.height = desc.Width, desc.Height
			desc.Usage, desc.BindFlags, desc.MiscFlags = .STAGING, {}, {}
			desc.CPUAccessFlags = {.READ}
			if failed(r.device_11.CreateTexture2D(r.device_11, &desc, nil, &s.staging)) {
				return screenshot_fail(s, .GPU)
			}
			s.context_11 = r.context_11
			s.context_11.AddRef(s.context_11)
		}
		held_key := u64(1)
		if !video_mutex_acquire(r.render_mutex, held_key) {
			held_key = 0
			if !video_mutex_acquire(r.render_mutex, held_key) do return false
		}
		s.vertical_flip = sync.atomic_load_explicit(&r.video_vertical_flip, .Acquire) != 0
		s.context_11.CopyResource(s.context_11, cast(^d3d11.IResource)s.staging, cast(^d3d11.IResource)r.video_texture)
		// Observe the frame without consuming the renderer's ready key. A
		// screenshot must not permit capture to overwrite an unpresented frame.
		r.render_mutex.ReleaseSync(r.render_mutex, held_key)
		// Submit the on-demand copy even if the source stops presenting. Flush
		// submits GPU commands; it does not wait for their completion.
		s.context_11.Flush(s.context_11)
		s.status = .Reading
		return false
	}
	readback: d3d11.MAPPED_SUBRESOURCE
	hr := s.context_11.Map(s.context_11, cast(^d3d11.IResource)s.staging, 0, .READ, {.DO_NOT_WAIT}, &readback)
	if hr == dxgi.ERROR_WAS_STILL_DRAWING do return false
	if failed(hr) do return screenshot_fail(s, .GPU)
	s.mapped = true
	if readback.pData == nil || readback.RowPitch < s.width*4 do return screenshot_fail(s, .GPU)
	s.job = new(Screenshot_Job, runtime.heap_allocator())
	if s.job == nil do return screenshot_fail(s, .Memory)
	s.job.source = cast([^]u8)readback.pData
	s.job.row_pitch, s.job.width, s.job.height = readback.RowPitch, s.width, s.height
	s.job.vertical_flip = s.vertical_flip
	s.worker = thread.create(screenshot_worker_proc, .Low, "elga-screenshot")
	if s.worker == nil {
		screenshot_free_job(s)
		return screenshot_fail(s, .Thread)
	}
	s.worker.data = s.job
	s.status = .Saving
	thread.start(s.worker)
	return false
}

screenshot_free_job :: proc(s: ^Screenshot_State) {
	if s.job == nil do return
	delete(s.job.path, runtime.heap_allocator())
	free(s.job, runtime.heap_allocator())
	s.job = nil
}

// Call before renderer_destroy. Cancellation never terminates a thread while
// it owns memory or a file. The single encoder is joined only during shutdown.
screenshot_destroy :: proc(s: ^Screenshot_State) {
	if s.worker != nil {
		sync.atomic_store_explicit(&s.job.cancel_requested, 1, .Release)
		thread.join(s.worker)
		thread.destroy(s.worker)
		s.worker = nil
	}
	screenshot_release_readback(s)
	screenshot_free_job(s)
	delete(s.last_path, runtime.heap_allocator())
	s^ = {}
}

screenshot_dimensions_valid :: proc(width, height: u32) -> bool {
	// D3D11 textures are at most 16384 on either axis; also cap the CPU image
	// buffer and the PNG encoder's signed-int sizes before doing multiplication.
	return width > 0 && height > 0 && width <= 16384 && height <= 16384 && u64(width)*u64(height)*4 <= 512*1024*1024
}

// Converts one BGRA row to RGB. Alpha from a capture source is deliberately
// ignored: screenshots are opaque even when the device supplies zero alpha.
screenshot_copy_rgb_row :: proc(destination: []u8, source: [^]u8, row_pitch, width, height, y: u32, vertical_flip: bool) {
	source_y := height-1-y if vertical_flip else y
	row_start := int(source_y)*int(row_pitch)
	row := source[row_start:row_start+int(width)*4]
	for x in 0..<int(width) {
		destination[x*3+0] = row[x*4+2]
		destination[x*3+1] = row[x*4+1]
		destination[x*3+2] = row[x*4+0]
	}
}

screenshot_cancelled :: proc(job: ^Screenshot_Job) -> bool {
	return sync.atomic_load_explicit(&job.cancel_requested, .Acquire) != 0
}

screenshot_worker_proc :: proc(t: ^thread.Thread) {
	job := cast(^Screenshot_Job)t.data
	job.error = .Cancelled
	if screenshot_cancelled(job) do return
	pixels := make([]u8, int(job.width)*int(job.height)*3)
	if pixels == nil {
		job.error = .Memory
		return
	}
	defer delete(pixels)
	row_bytes := int(job.width)*3
	for y in 0..<job.height {
		if screenshot_cancelled(job) do return
		screenshot_copy_rgb_row(pixels[int(y)*row_bytes:][:row_bytes], job.source, job.row_pitch, job.width, job.height, y, job.vertical_flip)
	}
	if screenshot_cancelled(job) do return
	folder := screenshot_folder()
	if folder == "" {
		job.error = .Folder
		return
	}
	defer delete(folder, runtime.heap_allocator())
	job.file, job.path = screenshot_open_unique(folder, time.now())
	if job.file == win32.INVALID_HANDLE || job.file == nil {
		job.error = .File
		return
	}
	job.write_ok = true
	encoded := stbi.write_png_to_func(screenshot_write_callback, job, c.int(job.width), c.int(job.height), 3, raw_data(pixels), c.int(row_bytes)) != 0
	if !win32.CloseHandle(job.file) do job.write_ok = false
	job.file = nil
	if screenshot_cancelled(job) {
		job.error = .Cancelled
	} else if !job.write_ok {
		job.error = .File
	} else if !encoded {
		job.error = .Encoding
	} else {
		job.error = .None
	}
	if job.error != .None {
		wide := win32.utf8_to_utf16(job.path)
		if len(wide) > 0 do win32.DeleteFileW(cstring16(raw_data(wide)))
	}
}

screenshot_write_callback :: proc "c" (data: rawptr, bytes: rawptr, size: c.int) {
	context = runtime.default_context()
	job := cast(^Screenshot_Job)data
	if !job.write_ok || screenshot_cancelled(job) || size <= 0 {
		job.write_ok = false
		return
	}
	offset := u32(0)
	for offset < u32(size) {
		written: u32
		if !win32.WriteFile(job.file, mem.ptr_offset(cast(^u8)bytes, int(offset)), u32(size)-offset, &written, nil) || written == 0 {
			job.write_ok = false
			return
		}
		offset += written
	}
}

screenshot_folder :: proc() -> string {
	context.allocator = runtime.heap_allocator()
	// Respect redirected Pictures locations, including OneDrive and Unicode
	// profiles. Portable installations fall back to Screenshots by the exe.
	base: string
	known_path: win32.LPWSTR
	pictures_id := win32.FOLDERID_Pictures
	if !failed(win32.SHGetKnownFolderPath(&pictures_id, 0, nil, &known_path)) && known_path != nil {
		base = win32.wstring_to_utf8(cstring16(known_path), -1, context.allocator) or_else ""
	}
	if known_path != nil do win32.CoTaskMemFree(known_path)
	defer delete(base)
	folder: string
	if base != "" {
		folder = fmt.aprintf("%s\\Elga", base)
	} else {
		executable: [32768]u16
		count := win32.GetModuleFileNameW(nil, &executable[0], u32(len(executable)))
		if count == 0 || count >= u32(len(executable)) do return ""
		end := int(count)-1
		for end >= 0 && executable[end] != '\\' && executable[end] != '/' do end -= 1
		if end < 0 do return ""
		base = win32.utf16_to_utf8(executable[:end], context.allocator) or_else ""
		if base == "" do return ""
		folder = fmt.aprintf("%s\\Screenshots", base)
	}
	wide := win32.utf8_to_utf16(folder)
	if len(wide) > 0 {
		if win32.CreateDirectoryW(cstring16(raw_data(wide)), nil) do return folder
		attributes := win32.GetFileAttributesW(cstring16(raw_data(wide)))
		if attributes != win32.INVALID_FILE_ATTRIBUTES && attributes & win32.FILE_ATTRIBUTE_DIRECTORY != 0 do return folder
	}
	delete(folder)
	return ""
}

// CREATE_NEW is the ownership boundary: same-millisecond presses and other
// running app instances cannot overwrite an existing screenshot.
screenshot_open_unique :: proc(folder: string, timestamp: time.Time) -> (win32.HANDLE, string) {
	context.allocator = runtime.heap_allocator()
	dt, valid := time.time_to_datetime(timestamp)
	if !valid do return win32.INVALID_HANDLE, ""
	for attempt in 0..<10000 {
		path := fmt.aprintf("%s\\Elga-%04d%02d%02d-%02d%02d%02d-%03dZ-%03d.png", folder,
			dt.date.year, dt.date.month, dt.date.day, dt.time.hour, dt.time.minute, dt.time.second, dt.time.nano/1000000, attempt)
		wide := win32.utf8_to_utf16(path, context.allocator)
		if len(wide) == 0 {
			delete(path)
			return win32.INVALID_HANDLE, ""
		}
		file := win32.CreateFileW(cstring16(raw_data(wide)), win32.GENERIC_WRITE, win32.FILE_SHARE_READ, nil, win32.CREATE_NEW, win32.FILE_ATTRIBUTE_NORMAL, nil)
		error := win32.GetLastError()
		delete(wide)
		if file != win32.INVALID_HANDLE do return file, path
		delete(path)
		if error != win32.ERROR_FILE_EXISTS && error != win32.ERROR_ALREADY_EXISTS do return win32.INVALID_HANDLE, ""
	}
	return win32.INVALID_HANDLE, ""
}
