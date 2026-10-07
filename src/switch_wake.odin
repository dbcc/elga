package main

import c "core:c/libc"
import "core:fmt"
import "core:sync"
import "core:thread"
import "core:time"
import win32 "core:sys/windows"
import curl "vendor:curl"

SWITCH_WAKE_URL                :: cstring("http://switch2-waker.local/button/Wake%20Switch%202/press")
SWITCH_WAKE_HEALTH_URL         :: cstring("http://switch2-waker.local/button/Wake%20Switch%202")
SWITCH_WAKE_HEALTH_INTERVAL_MS :: 5000
SWITCH_WAKE_RESULT_DURATION    :: 2*time.Second

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

@(rodata)
WAKE_ERROR_REASON := [Wake_Error]cstring{
	.None                = "transfer failed",
	.Curl_Global_Init    = "libcurl initialization failed",
	.Health_Monitor_Init = "health monitor could not start",
	.Thread_Create       = "could not create worker thread",
	.Curl_Easy_Init      = "could not create curl request",
	.Curl_Setup          = "could not configure curl",
	.Resolve             = "could not resolve switch2-waker.local",
	.Connect             = "could not connect to beacon",
	.Timeout             = "beacon timed out",
	.Http                = "beacon returned HTTP %d",
	.Cancelled           = "request was cancelled",
	.Transfer            = "transfer failed",
}

// Status fields are written by the worker threads and read by the window thread.
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
	result_visible_since: time.Time,
}

wake_init :: proc(w: ^Wake_Control) -> bool {
	init_error := Wake_Error.None
	if curl.global_init(curl.GLOBAL_DEFAULT) != .E_OK {
		init_error = .Curl_Global_Init
	} else {
		w.health_event = win32.CreateEventW(nil, false, false, nil)
		if w.health_event != nil do w.health_thread = thread.create(wake_health_thread_proc, .Low, "switch-health")
		if w.health_thread == nil {
			if w.health_event != nil do win32.CloseHandle(w.health_event)
			w.health_event = nil
			curl.global_cleanup()
			init_error = .Health_Monitor_Init
		}
	}
	if init_error != .None {
		fmt.eprintf("Switch wake: unavailable (%v)\n", init_error)
		wake_set_health(w, false, init_error)
		wake_set_result(w, .Unavailable, init_error)
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
	for worker in ([2]^^thread.Thread{&w.request_thread, &w.health_thread}) {
		if worker^ == nil do continue
		thread.join(worker^)
		thread.destroy(worker^)
		worker^ = nil
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
	w.result_visible_since = {}
}

// Window thread. Reports whether anything the UI shows has changed.
wake_update :: proc(w: ^Wake_Control) -> bool {
	changed := false
	now := time.now()
	if w.request_thread != nil && wake_get_status(w) != .Sending {
		thread.join(w.request_thread)
		thread.destroy(w.request_thread)
		w.request_thread = nil
		w.result_visible_since = now
		changed = true
	}
	if wake_expire_result(w, now) do changed = true
	generation := sync.atomic_load_explicit(&w.generation, .Acquire)
	changed = changed || generation != w.observed_generation
	w.observed_generation = generation
	return changed
}

wake_request :: proc(w: ^Wake_Control) {
	if !w.initialized || !wake_is_online(w) || w.request_thread != nil do return
	w.result_visible_since = {}
	wake_set_result(w, .Sending, .None)
	w.request_thread = thread.create(wake_request_thread_proc, .Normal, "switch-wake")
	if w.request_thread == nil {
		wake_set_result(w, .Failed, .Thread_Create)
		w.result_visible_since = time.now()
		fmt.eprintln("Switch wake: could not create request thread")
		return
	}
	w.request_thread.data = w
	thread.start(w.request_thread)
}

wake_request_in_flight :: proc(w: ^Wake_Control) -> bool {
	return w.request_thread != nil
}

wake_expire_result :: proc(w: ^Wake_Control, now: time.Time) -> bool {
	if w.result_visible_since == {} do return false
	status := wake_get_status(w)
	if status != .Success && status != .Failed {
		w.result_visible_since = {}
		return false
	}
	if time.diff(w.result_visible_since, now) < SWITCH_WAKE_RESULT_DURATION do return false
	w.result_visible_since = {}
	wake_set_result(w, .Idle, .None)
	return true
}

wake_get_status :: proc(w: ^Wake_Control) -> Wake_Status {
	return Wake_Status(sync.atomic_load_explicit(&w.status, .Acquire))
}

wake_get_error :: proc(w: ^Wake_Control) -> Wake_Error {
	return Wake_Error(sync.atomic_load_explicit(&w.error, .Acquire))
}

wake_is_online :: proc(w: ^Wake_Control) -> bool {
	return sync.atomic_load_explicit(&w.online, .Acquire) != 0
}

wake_tooltip :: proc(w: ^Wake_Control) -> cstring {
	reason :: proc(error: Wake_Error, http_status: u32) -> cstring {
		return fmt.ctprintf(string(WAKE_ERROR_REASON[error]), http_status) if error == .Http else WAKE_ERROR_REASON[error]
	}
	if !wake_is_online(w) {
		if sync.atomic_load_explicit(&w.health_checked, .Acquire) == 0 do return "Checking Switch 2 wake beacon..."
		error := Wake_Error(sync.atomic_load_explicit(&w.health_error, .Acquire))
		return fmt.ctprintf("Wake unavailable: %s", reason(error, sync.atomic_load_explicit(&w.health_http_status, .Acquire)))
	}
	switch wake_get_status(w) {
	case .Unavailable: return "Switch wake is unavailable"
	case .Idle:        return "Wake Nintendo Switch 2"
	case .Sending:     return "Sending Switch 2 wake request..."
	case .Success:     return "Switch 2 wake request sent"
	case .Failed:
		return fmt.ctprintf("Switch wake failed: %s", reason(wake_get_error(w), sync.atomic_load_explicit(&w.http_status, .Acquire)))
	}
	return ""
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
		online, error, http_status := wake_http_request(w, SWITCH_WAKE_HEALTH_URL, false)
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

wake_request_thread_proc :: proc(t: ^thread.Thread) {
	w := cast(^Wake_Control)t.data
	if w == nil do return
	ok, error, http_status := wake_http_request(w, SWITCH_WAKE_URL, true)
	if ok {
		fmt.eprintln("Switch wake: request sent")
		wake_set_health(w, true, .None, http_status)
	} else {
		fmt.eprintf("Switch wake: request failed (%v, HTTP %d)\n", error, http_status)
		if error != .Cancelled do wake_set_health(w, false, error, http_status)
	}
	wake_set_result(w, .Success if ok else .Failed, error, http_status)
}

// Health probes and wake requests share timeouts, cancellation, and status handling.
wake_http_request :: proc(w: ^Wake_Control, url: cstring, post: bool) -> (ok: bool, error: Wake_Error, http_status: u32) {
	easy := curl.easy_init()
	if easy == nil do return false, .Curl_Easy_Init, 0
	defer curl.easy_cleanup(easy)

	options_ok := curl.easy_setopt(easy, .URL, url) == .E_OK &&
		curl.easy_setopt(easy, .CONNECTTIMEOUT_MS, c.long(5000)) == .E_OK &&
		curl.easy_setopt(easy, .TIMEOUT_MS, c.long(8000)) == .E_OK &&
		curl.easy_setopt(easy, .NOSIGNAL, c.long(1)) == .E_OK &&
		curl.easy_setopt(easy, .FAILONERROR, c.long(1)) == .E_OK &&
		curl.easy_setopt(easy, .NOPROGRESS, c.long(0)) == .E_OK &&
		curl.easy_setopt(easy, .XFERINFOFUNCTION, wake_cancel_transfer) == .E_OK &&
		curl.easy_setopt(easy, .XFERINFODATA, w) == .E_OK &&
		curl.easy_setopt(easy, .WRITEFUNCTION, wake_discard_response) == .E_OK
	if options_ok && post {
		options_ok = curl.easy_setopt(easy, .POST, c.long(1)) == .E_OK &&
			curl.easy_setopt(easy, .POSTFIELDSIZE, c.long(0)) == .E_OK
	}
	if !options_ok do return false, .Curl_Setup, 0

	result := curl.easy_perform(easy)
	response_code: c.long
	info_result := curl.easy_getinfo(easy, .RESPONSE_CODE, &response_code)
	if response_code > 0 do http_status = u32(response_code)
	if result == .E_OK && info_result == .E_OK && response_code >= 200 && response_code < 300 do return true, .None, http_status
	return false, wake_classify_error(result, info_result), http_status
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
