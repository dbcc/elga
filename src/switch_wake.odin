package main

import c "core:c/libc"
import "core:fmt"
import "core:sync"
import "core:thread"
import win32 "core:sys/windows"
import curl "vendor:curl"

SWITCH_WAKE_URL                :: cstring("http://switch2-waker.local/button/Wake%20Switch%202/press")
SWITCH_WAKE_HEALTH_URL         :: cstring("http://switch2-waker.local/button/Wake%20Switch%202")
SWITCH_WAKE_HEALTH_INTERVAL_MS :: 5000

Wake_Status :: enum u32 {
	Unavailable,
	Idle,
	Sending,
	Success,
	Failed,
}

Wake_Error :: enum u32 {
	None,
	Curl_Global_Init,
	Health_Monitor_Init,
	Thread_Create,
	Curl_Easy_Init,
	Curl_Setup,
	Resolve,
	Connect,
	Timeout,
	Http,
	Cancelled,
	Transfer,
}

Wake_Control :: struct {
	initialized:      bool,
	request_thread:   ^thread.Thread,
	health_thread:    ^thread.Thread,
	health_event:     win32.HANDLE,
	status:           u32,
	error:            u32,
	http_status:      u32,
	online:           u32,
	health_checked:   u32,
	health_error:     u32,
	health_http_status: u32,
	cancel_requested: u32,
	generation:       u32,
	observed_generation: u32,
}

wake_init :: proc(w: ^Wake_Control) -> bool {
	sync.atomic_store_explicit(&w.online, 0, .Relaxed)
	sync.atomic_store_explicit(&w.health_checked, 0, .Relaxed)
	sync.atomic_store_explicit(&w.health_error, u32(Wake_Error.None), .Relaxed)
	sync.atomic_store_explicit(&w.health_http_status, 0, .Relaxed)
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK {
		fmt.eprintln("Switch wake: could not initialize libcurl")
		wake_set_health(w, false, .Curl_Global_Init)
		wake_set_result(w, .Unavailable, .Curl_Global_Init)
		return false
	}
	sync.atomic_store_explicit(&w.cancel_requested, 0, .Release)
	w.health_event = win32.CreateEventW(nil, false, false, nil)
	if w.health_event == nil {
		curl.global_cleanup()
		wake_set_health(w, false, .Health_Monitor_Init)
		wake_set_result(w, .Unavailable, .Health_Monitor_Init)
		return false
	}
	w.health_thread = thread.create(wake_health_thread_proc, .Low, "switch-health")
	if w.health_thread == nil {
		win32.CloseHandle(w.health_event)
		w.health_event = nil
		curl.global_cleanup()
		wake_set_health(w, false, .Health_Monitor_Init)
		wake_set_result(w, .Unavailable, .Health_Monitor_Init)
		return false
	}
	w.health_thread.data = w
	thread.start(w.health_thread)
	w.initialized = true
	wake_set_result(w, .Idle, .None)
	return true
}

wake_destroy :: proc(w: ^Wake_Control) {
	sync.atomic_store_explicit(&w.cancel_requested, 1, .Release)
	if w.health_event != nil do win32.SetEvent(w.health_event)
	if w.request_thread != nil {
		thread.join(w.request_thread)
		thread.destroy(w.request_thread)
		w.request_thread = nil
	}
	if w.health_thread != nil {
		thread.join(w.health_thread)
		thread.destroy(w.health_thread)
		w.health_thread = nil
	}
	if w.health_event != nil {
		win32.CloseHandle(w.health_event)
		w.health_event = nil
	}
	if w.initialized {
		curl.global_cleanup()
		w.initialized = false
	}
	wake_set_result(w, .Unavailable, .None)
}

wake_update :: proc(w: ^Wake_Control) -> bool {
	if w.request_thread != nil && wake_get_status(w) != .Sending {
		thread.join(w.request_thread)
		thread.destroy(w.request_thread)
		w.request_thread = nil
	}
	generation := sync.atomic_load_explicit(&w.generation, .Acquire)
	changed := generation != w.observed_generation
	w.observed_generation = generation
	return changed
}

wake_request :: proc(w: ^Wake_Control) {
	if !w.initialized || !wake_is_online(w) || w.request_thread != nil do return
	wake_set_result(w, .Sending, .None)
	w.request_thread = thread.create(wake_request_thread_proc, .Normal, "switch-wake")
	if w.request_thread == nil {
		wake_set_result(w, .Failed, .Thread_Create)
		fmt.eprintln("Switch wake: could not create request thread")
		return
	}
	w.request_thread.data = w
	thread.start(w.request_thread)
}

wake_get_status :: proc(w: ^Wake_Control) -> Wake_Status {
	return Wake_Status(sync.atomic_load_explicit(&w.status, .Acquire))
}

wake_get_error :: proc(w: ^Wake_Control) -> Wake_Error {
	return Wake_Error(sync.atomic_load_explicit(&w.error, .Acquire))
}

wake_get_http_status :: proc(w: ^Wake_Control) -> u32 {
	return sync.atomic_load_explicit(&w.http_status, .Acquire)
}

wake_is_online :: proc(w: ^Wake_Control) -> bool {
	return sync.atomic_load_explicit(&w.online, .Acquire) != 0
}

wake_health_was_checked :: proc(w: ^Wake_Control) -> bool {
	return sync.atomic_load_explicit(&w.health_checked, .Acquire) != 0
}

wake_get_health_error :: proc(w: ^Wake_Control) -> Wake_Error {
	return Wake_Error(sync.atomic_load_explicit(&w.health_error, .Acquire))
}

wake_get_health_http_status :: proc(w: ^Wake_Control) -> u32 {
	return sync.atomic_load_explicit(&w.health_http_status, .Acquire)
}

wake_set_result :: proc(w: ^Wake_Control, status: Wake_Status, error: Wake_Error, http_status: u32 = 0) {
	sync.atomic_store_explicit(&w.http_status, http_status, .Relaxed)
	sync.atomic_store_explicit(&w.error, u32(error), .Relaxed)
	sync.atomic_store_explicit(&w.status, u32(status), .Release)
	sync.atomic_add_explicit(&w.generation, 1, .Release)
}

wake_set_health :: proc(w: ^Wake_Control, online: bool, error: Wake_Error, http_status: u32 = 0) {
	sync.atomic_store_explicit(&w.health_http_status, http_status, .Relaxed)
	sync.atomic_store_explicit(&w.health_error, u32(error), .Relaxed)
	sync.atomic_store_explicit(&w.online, 1 if online else 0, .Release)
	sync.atomic_store_explicit(&w.health_checked, 1, .Release)
	sync.atomic_add_explicit(&w.generation, 1, .Release)
}

wake_health_thread_proc :: proc(t: ^thread.Thread) {
	w := cast(^Wake_Control)t.data
	if w == nil do return
	for sync.atomic_load_explicit(&w.cancel_requested, .Acquire) == 0 {
		online, error, http_status := wake_probe(w)
		if sync.atomic_load_explicit(&w.cancel_requested, .Acquire) != 0 do break
		wake_set_health(w, online, error, http_status)
		wait_result := win32.WaitForSingleObject(w.health_event, SWITCH_WAKE_HEALTH_INTERVAL_MS)
		if wait_result == win32.WAIT_FAILED {
			wake_set_health(w, false, .Health_Monitor_Init)
			break
		}
		if wait_result != win32.WAIT_TIMEOUT do break
	}
}

wake_probe :: proc(w: ^Wake_Control) -> (online: bool, error: Wake_Error, http_status: u32) {
	error = .Transfer
	easy := curl.easy_init()
	if easy == nil {
		return false, .Curl_Easy_Init, 0
	}
	defer curl.easy_cleanup(easy)

	options_ok := curl.easy_setopt(easy, .URL, SWITCH_WAKE_HEALTH_URL) == .E_OK &&
		curl.easy_setopt(easy, .CONNECTTIMEOUT_MS, c.long(5000)) == .E_OK &&
		curl.easy_setopt(easy, .TIMEOUT_MS, c.long(8000)) == .E_OK &&
		curl.easy_setopt(easy, .NOSIGNAL, c.long(1)) == .E_OK &&
		curl.easy_setopt(easy, .FAILONERROR, c.long(1)) == .E_OK &&
		curl.easy_setopt(easy, .NOPROGRESS, c.long(0)) == .E_OK &&
		curl.easy_setopt(easy, .XFERINFOFUNCTION, wake_cancel_transfer) == .E_OK &&
		curl.easy_setopt(easy, .XFERINFODATA, w) == .E_OK &&
		curl.easy_setopt(easy, .WRITEFUNCTION, wake_discard_response) == .E_OK
	if !options_ok {
		return false, .Curl_Setup, 0
	}

	result := curl.easy_perform(easy)
	response_code: c.long
	info_result := curl.easy_getinfo(easy, .RESPONSE_CODE, &response_code)
	if response_code > 0 do http_status = u32(response_code)
	online = result == .E_OK && info_result == .E_OK && response_code >= 200 && response_code < 300
	if online do return true, .None, http_status
	return false, wake_classify_error(result, info_result), http_status
}

wake_request_thread_proc :: proc(t: ^thread.Thread) {
	w := cast(^Wake_Control)t.data
	if w == nil do return
	succeeded := false
	error := Wake_Error.Transfer
	http_status: u32
	defer wake_set_result(w, .Success if succeeded else .Failed, .None if succeeded else error, http_status)

	easy := curl.easy_init()
	if easy == nil {
		error = .Curl_Easy_Init
		fmt.eprintln("Switch wake: could not create curl request")
		return
	}
	defer curl.easy_cleanup(easy)

	options_ok := curl.easy_setopt(easy, .URL, SWITCH_WAKE_URL) == .E_OK &&
		curl.easy_setopt(easy, .POST, c.long(1)) == .E_OK &&
		curl.easy_setopt(easy, .POSTFIELDSIZE, c.long(0)) == .E_OK &&
		curl.easy_setopt(easy, .CONNECTTIMEOUT_MS, c.long(5000)) == .E_OK &&
		curl.easy_setopt(easy, .TIMEOUT_MS, c.long(8000)) == .E_OK &&
		curl.easy_setopt(easy, .NOSIGNAL, c.long(1)) == .E_OK &&
		curl.easy_setopt(easy, .FAILONERROR, c.long(1)) == .E_OK &&
		curl.easy_setopt(easy, .NOPROGRESS, c.long(0)) == .E_OK &&
		curl.easy_setopt(easy, .XFERINFOFUNCTION, wake_cancel_transfer) == .E_OK &&
		curl.easy_setopt(easy, .XFERINFODATA, w) == .E_OK &&
		curl.easy_setopt(easy, .WRITEFUNCTION, wake_discard_response) == .E_OK
	if !options_ok {
		error = .Curl_Setup
		fmt.eprintln("Switch wake: could not configure curl request")
		return
	}

	result := curl.easy_perform(easy)
	response_code: c.long
	info_result := curl.easy_getinfo(easy, .RESPONSE_CODE, &response_code)
	if response_code > 0 do http_status = u32(response_code)
	succeeded = result == .E_OK && info_result == .E_OK && response_code >= 200 && response_code < 300
	if !succeeded {
		error = wake_classify_error(result, info_result)
		if error != .Cancelled do wake_set_health(w, false, error, http_status)
	} else {
		wake_set_health(w, true, .None, http_status)
	}
	if succeeded {
		fmt.eprintln("Switch wake: request sent")
	} else {
		fmt.eprintf("Switch wake: request failed (%s, HTTP %d)\n", curl.easy_strerror(result), response_code)
	}
}

wake_classify_error :: proc(result, info_result: curl.code) -> Wake_Error {
	#partial switch result {
	case .E_COULDNT_RESOLVE_PROXY, .E_COULDNT_RESOLVE_HOST: return .Resolve
	case .E_COULDNT_CONNECT:                              return .Connect
	case .E_OPERATION_TIMEDOUT:                           return .Timeout
	case .E_HTTP_RETURNED_ERROR:                          return .Http
	case .E_ABORTED_BY_CALLBACK:                          return .Cancelled
	case .E_OK:                                           return .Http if info_result == .E_OK else .Transfer
	case:                                                 return .Transfer
	}
}

wake_cancel_transfer :: proc "c" (userdata: rawptr, download_total, download_now, upload_total, upload_now: curl.off_t) -> c.int {
	w := cast(^Wake_Control)userdata
	if w != nil && sync.atomic_load_explicit(&w.cancel_requested, .Acquire) != 0 do return 1
	return 0
}

wake_discard_response :: proc "c" (buffer: [^]byte, size, count: c.size_t, userdata: rawptr) -> c.size_t {
	return size*count
}
