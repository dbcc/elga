package main

import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:testing"
import win32 "core:sys/windows"

test_window_layout :: proc() -> Window_Layout {
	layout := Window_Layout{
		rect = win32.RECT{-1800, 120, -520, 840},
		work = win32.RECT{-1920, 40, 0, 1080},
		dpi = 96,
		always_on_top = true,
	}
	name := `\\.\DISPLAY2`
	for i in 0..<len(name) do layout.monitor[i] = u16(name[i])
	return layout
}

test_window_layout_replace :: proc(value, old, replacement: string) -> string {
	result, _ := strings.replace_all(value, old, replacement, context.temp_allocator)
	return result
}

@(test)
window_layout_monitor_dpi_restore_test :: proc(t: ^testing.T) {
	layout := test_window_layout()
	testing.expect_value(t, window_layout_fit(layout, layout.work, 96), layout.rect)

	// Same monitor moved to the right and changed from 100% to 150% scaling.
	work := win32.RECT{1920, 60, 4800, 1620}
	testing.expect_value(t, window_layout_fit(layout, work, 144), win32.RECT{2100, 180, 4020, 1260})

	// Restore from a missing large display onto a small remaining monitor.
	layout.rect = win32.RECT{-1920, 40, 1920, 2200}
	work = win32.RECT{0, 0, 1280, 680}
	restored := window_layout_fit(layout, work, 96)
	testing.expect_value(t, restored, win32.RECT{0, 0, 1208, 680})

	// A saved position outside the available area stays reachable after restore.
	layout = test_window_layout()
	layout.rect = win32.RECT{-100, 900, 1180, 1620}
	work = win32.RECT{0, 40, 1920, 1080}
	testing.expect_value(t, window_layout_fit(layout, work, 96), win32.RECT{640, 360, 1920, 1080})

	// Maliciously tiny saved geometry respects the normal minimum on a large screen.
	layout.rect = win32.RECT{-1920, 40, -1919, 41}
	testing.expect_value(t, window_layout_fit(layout, work, 192), win32.RECT{0, 40, 640, 484})
}

@(test)
window_layout_normal_placement_test :: proc(t: ^testing.T) {
	// Top/left taskbars add workspace offsets to GetWindowPlacement coordinates.
	monitor := win32.RECT{-1920, 0, 0, 1080}
	work := win32.RECT{-1880, 40, 0, 1080}
	normal := win32.RECT{-1820, 60, -540, 780}
	testing.expect_value(t, window_layout_screen_rect(normal, monitor, work), win32.RECT{-1780, 100, -500, 820})

	// Fullscreen geometry must never replace the last normal placement; changing
	// topmost while fullscreen should still be remembered.
	state := Window_Layout_State{layout = test_window_layout(), valid = true}
	saved_rect := state.rect
	window_layout_observe(&state, nil, true, false)
	testing.expect_value(t, state.rect, saved_rect)
	testing.expect(t, !state.always_on_top)
	testing.expect(t, state.dirty)
}

@(test)
window_layout_settings_validation_test :: proc(t: ^testing.T) {
	layout := test_window_layout()
	buffer: [1024]byte
	settings := window_layout_format(buffer[:], layout)
	parsed, ok := window_layout_parse(settings)
	testing.expect(t, ok)
	testing.expect_value(t, parsed, layout)

	invalid_settings := []string{
		"", "[window]\nx=0\n", "[window]\nmonitor=x\nversion=1\n",
		test_window_layout_replace(settings, "version=1", "version=2"),
		test_window_layout_replace(settings, "dpi=96", "dpi=0"),
		test_window_layout_replace(settings, "width=1280", "width=-1280"),
		test_window_layout_replace(settings, "always_on_top=1", "always_on_top=2"),
		test_window_layout_replace(settings, "x=-1800", "x=99999999999999999999999"),
		test_window_layout_replace(settings, "version=1", "version=1\nversion=1"),
	}
	for invalid in invalid_settings {
		_, valid := window_layout_parse(invalid)
		testing.expect(t, !valid)
	}
}

@(test)
window_layout_save_failure_retry_test :: proc(t: ^testing.T) {
	directory, err := os.make_directory_temp("", "elga-layout-test-*", context.temp_allocator)
	testing.expect(t, err == nil)
	if err != nil do return
	path, temp_path, paths_ok := window_layout_paths_for_directory(directory, 1001)
	testing.expect(t, paths_ok)
	_, other_temp, other_ok := window_layout_paths_for_directory(directory, 1002)
	testing.expect(t, other_ok && temp_path != other_temp)
	audio_path, audio_error := filepath.join([]string{directory, AUDIO_SETTINGS_FILE}, context.temp_allocator)
	testing.expect(t, audio_error == nil)
	blocker, blocker_error := filepath.join([]string{directory, "blocker"}, context.temp_allocator)
	testing.expect(t, blocker_error == nil)
	bad_temp, bad_error := filepath.join([]string{blocker, "layout.tmp"}, context.temp_allocator)
	testing.expect(t, bad_error == nil)
	defer {
		_ = os.remove(path)
		_ = os.remove(temp_path)
		_ = os.remove(audio_path)
		_ = os.remove(blocker)
		_ = os.remove(directory)
	}
	testing.expect(t, os.write_entire_file(audio_path, "[audio]\nvolume_percent=42\n") == nil)
	testing.expect(t, os.write_entire_file(blocker, "not a directory") == nil)
	saved := Window_Layout_State{layout = test_window_layout(), valid = true, dirty = true}
	testing.expect(t, window_layout_save_to_paths(&saved, path, temp_path))
	testing.expect(t, !saved.dirty && !saved.save_failed)
	loaded: Window_Layout_State
	testing.expect(t, window_layout_load_from_path(&loaded, path))
	testing.expect_value(t, loaded.layout, saved.layout)

	old_layout := saved.layout
	saved.always_on_top = false
	saved.dirty = true
	testing.expect(t, !window_layout_save_to_paths(&saved, path, bad_temp))
	testing.expect(t, saved.dirty && saved.save_failed)
	testing.expect(t, window_layout_load_from_path(&loaded, path))
	testing.expect_value(t, loaded.layout, old_layout)
	testing.expect(t, window_layout_save_to_paths(&saved, path, temp_path))
	testing.expect(t, !saved.dirty && !saved.save_failed)
	testing.expect(t, window_layout_load_from_path(&loaded, path))
	testing.expect_value(t, loaded.layout, saved.layout)

	// A rename failure also leaves the existing settings intact and cleans up.
	saved.dirty = true
	testing.expect(t, !window_layout_save_to_paths(&saved, directory, temp_path))
	testing.expect(t, saved.dirty && saved.save_failed)
	testing.expect(t, !os.exists(temp_path))
	testing.expect(t, window_layout_load_from_path(&loaded, path))
	testing.expect_value(t, loaded.layout, saved.layout)
	audio_data, read_error := os.read_entire_file(audio_path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, string(audio_data), "[audio]\nvolume_percent=42\n")

	testing.expect(t, os.write_entire_file(path, "[window]\nversion=broken\n") == nil)
	testing.expect(t, !window_layout_load_from_path(&loaded, path))
	testing.expect_value(t, loaded.layout, saved.layout)
	oversized: [4097]byte
	testing.expect(t, os.write_entire_file(path, oversized[:]) == nil)
	testing.expect(t, !window_layout_load_from_path(&loaded, path))
	testing.expect_value(t, loaded.layout, saved.layout)
}
