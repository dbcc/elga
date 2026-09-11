package main

import "core:testing"
import "core:sync"
import win32 "core:sys/windows"
import imgui "../vendor/odin-imgui"

// Dear ImGui stores its current context globally, even for private contexts.
// Serialize these fixtures while the rest of the suite runs in parallel.
test_imgui_mutex: sync.Mutex

@(test)
imgui_focus_events_remain_bounded_without_rendering_test :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_imgui_mutex)
	defer sync.mutex_unlock(&test_imgui_mutex)
	previous_context := imgui.GetCurrentContext()
	ui_context := imgui.CreateContext()
	defer {
		imgui.DestroyContext(ui_context)
		imgui.SetCurrentContext(previous_context)
	}
	imgui.SetCurrentContext(ui_context)
	io := imgui.GetIO()
	ui := ImGui_State{ready = true}
	imgui.IO_AddMouseButtonEvent(io, 0, true)
	imgui.UpdateInputEvents(true)
	testing.expect(t, io.MouseDown[0])
	// Fullscreen can hide the overlay indefinitely, and minimized windows also
	// skip NewFrame. Focus notifications must not build an unbounded queue.
	for _ in 0..<10000 {
		imgui_ui_process_message(&ui, nil, win32.WM_KILLFOCUS, 0, 0)
		imgui_ui_process_message(&ui, nil, win32.WM_SETFOCUS, 0, 0)
	}
	testing.expect(t, ui_context.InputEventsQueue.Size <= 2)
	imgui_ui_flush_mouse_position(&ui, io)
	testing.expect(t, ui_context.InputEventsQueue.Size <= 2)
	imgui.UpdateInputEvents(false)
	testing.expect(t, !io.AppFocusLost)
	testing.expect(t, !io.MouseDown[0])
	testing.expect(t, !ui.focus_dirty && !ui.focus_lost)
	// Focus is applied before the first new click, so losing focus does not
	// discard a click delivered after the application is activated again.
	imgui_ui_process_message(&ui, nil, win32.WM_KILLFOCUS, 0, 0)
	imgui_ui_flush_mouse_position(&ui, io)
	imgui.UpdateInputEvents(false)
	testing.expect(t, io.AppFocusLost)
	imgui_ui_process_message(&ui, nil, win32.WM_SETFOCUS, 0, 0)
	imgui_ui_queue_mouse_button(&ui, io, 0, true, win32.MAKELPARAM(30, 40))
	imgui.UpdateInputEvents(false)
	testing.expect(t, !io.AppFocusLost)
	testing.expect(t, io.MouseDown[0])
	testing.expect_value(t, io.MousePos, imgui.Vec2{30, 40})
}

@(test)
imgui_mouse_input_order_test :: proc(t: ^testing.T) {
	sync.mutex_lock(&test_imgui_mutex)
	defer sync.mutex_unlock(&test_imgui_mutex)
	// A private ImGui context exercises real event trickling without a window,
	// D3D device, or changing the application's global UI state.
	previous_context := imgui.GetCurrentContext()
	ui_context := imgui.CreateContext()
	defer {
		imgui.DestroyContext(ui_context)
		imgui.SetCurrentContext(previous_context)
	}
	imgui.SetCurrentContext(ui_context)
	io := imgui.GetIO()
	ui: ImGui_State
	imgui.IO_AddMousePosEvent(io, 10, 20)
	imgui.UpdateInputEvents(true)

	// Several events arrive before a render: move, press, move, release, move.
	// Each button must retain its own location when consumed on later frames.
	ui.mouse_pos, ui.mouse_dirty = {100, 120}, true
	imgui_ui_queue_mouse_button(&ui, io, 0, true, win32.MAKELPARAM(100, 120))
	ui.mouse_pos, ui.mouse_dirty = {130, 140}, true
	imgui_ui_queue_mouse_button(&ui, io, 0, false, win32.MAKELPARAM(130, 140))
	ui.mouse_pos, ui.mouse_dirty = {200, 220}, true
	imgui_ui_flush_mouse_position(&ui, io)

	imgui.UpdateInputEvents(true)
	testing.expect_value(t, io.MousePos, imgui.Vec2{100, 120})
	testing.expect(t, io.MouseDown[0])
	imgui.UpdateInputEvents(true)
	testing.expect_value(t, io.MousePos, imgui.Vec2{130, 140})
	testing.expect(t, !io.MouseDown[0])
	imgui.UpdateInputEvents(true)
	testing.expect_value(t, io.MousePos, imgui.Vec2{200, 220})
	testing.expect(t, !ui.mouse_dirty)

	// Button coordinates also work without a preceding move notification,
	// including negative client coordinates while dragging outside the window.
	imgui_ui_queue_mouse_button(&ui, io, 1, true, win32.MAKELPARAM(-12, -34))
	imgui.UpdateInputEvents(true)
	testing.expect_value(t, io.MousePos, imgui.Vec2{-12, -34})
	testing.expect(t, io.MouseDown[1])
}
