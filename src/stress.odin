package main

import "core:fmt"
import "core:sync"
import "core:time"
import win32 "core:sys/windows"

// Debug harnesses compiled in only by their -define flags. ui_tick drives them.
ELGA_FULLSCREEN_STRESS :: #config(ELGA_FULLSCREEN_STRESS, false)
ELGA_FORMAT_STRESS     :: #config(ELGA_FORMAT_STRESS, false)

// Debug builds only (-define:ELGA_FULLSCREEN_STRESS=true): twelve transitions, then exit.
fullscreen_stress_tick :: proc() {
	@(static) started: time.Time
	@(static) step: int
	if started == {} {
		started = time.now()
		return
	}
	target_step := min(int(time.duration_seconds(time.since(started))/0.5), 12)
	for step < target_step {
		toggle_fullscreen()
		step += 1
		fmt.eprintf("fullscreen stress transition %d/12\n", step)
	}
	if step >= 12 do win32.PostMessageW(app.hwnd, win32.WM_CLOSE, 0, 0)
}

// Debug builds only (-define:ELGA_FORMAT_STRESS=true): cycles resolutions and formats, then exits.
format_stress_tick :: proc() {
	@(static) started: time.Time
	@(static) step: int
	if started == {} {
		started = time.now()
		return
	}
	r := &app.renderer
	target_step := min(int(time.duration_seconds(time.since(started))/3.0), 8)
	for step < target_step {
		fmt.eprintf("mode stress state: %s %dx%d sequence=%d display=%.1f FPS\n", CAPTURE_FORMAT_NAME[r.capture_format], r.mode.width, r.mode.height, sync.atomic_load_explicit(&r.video_sequence, .Acquire), r.display_fps)
		switch step {
		case 0: renderer_set_capture_resolution(r, 1920, 1080)
		case 1: renderer_set_capture_resolution(r, 1280, 720)
		case 2: renderer_set_capture_resolution(r, 2560, 1440)
		case 3: renderer_set_capture_resolution(r, 0, 0)
		case 4: renderer_set_capture_format(r, .P010)
		case 5: renderer_set_capture_format(r, .YUY2)
		case 6: renderer_set_capture_format(r, .NV12)
		case 7: win32.PostMessageW(app.hwnd, win32.WM_CLOSE, 0, 0)
		}
		step += 1
		fmt.eprintf("mode stress transition %d/8\n", step)
	}
}
