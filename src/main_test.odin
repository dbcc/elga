package main

import "base:runtime"
import "core:testing"
import win32 "core:sys/windows"

@(test)
window_messages_reclaim_temporary_memory_test :: proc(t: ^testing.T) {
	previous_layout := app.layout
	previous_ui_ready := app.ui.ready
	defer {
		app.layout = previous_layout
		app.ui.ready = previous_ui_ready
	}
	app.ui.ready = false
	// An invalid layout still allocates settings paths but cannot write them.
	// A nil window makes observing placement return without invoking Windows.
	app.layout = Window_Layout_State{dirty = true}

	context.temp_allocator = runtime.default_context().temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
	// Keep an outer allocation alive, as when Windows synchronously reenters a
	// callback. Reclaiming a message must preserve the caller's scratch memory.
	sentinel := make([]byte, 256, context.temp_allocator)
	for &value in sentinel do value = 0xa5
	arena := &runtime.global_default_temp_allocator_data.arena
	block := arena.curr_block
	used := block.used
	total_used := arena.total_used
	temp_count := arena.temp_count

	for _ in 0..<64 {
		window_proc(nil, win32.WM_EXITSIZEMOVE, 0, 0)
		if !testing.expect(t, arena.curr_block == block, "Window message retained a scratch allocation block") do return
		if !testing.expect_value(t, block.used, used) do return
		if !testing.expect_value(t, arena.total_used, total_used) do return
		if !testing.expect_value(t, arena.temp_count, temp_count) do return
	}
	for value in sentinel {
		if !testing.expect(t, value == byte(0xa5), "Window message invalidated its caller's scratch memory") do return
	}
	testing.expect(t, app.layout.dirty && app.layout.save_failed)
}
