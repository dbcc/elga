package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strconv"
import "core:strings"
import win32 "core:sys/windows"

WINDOW_LAYOUT_FILE :: "elga-window.ini"
WINDOW_LAYOUT_MAX_COORD :: 1_000_000

Window_Layout :: struct {
	rect:          win32.RECT,
	work:          win32.RECT,
	monitor:       [win32.CCHDEVICENAME]u16,
	dpi:           u32,
	always_on_top: bool,
}

Window_Layout_State :: struct {
	using layout: Window_Layout,
	valid:        bool,
	dirty:        bool,
	save_failed:  bool,
}

Window_Layout_Monitor_Search :: struct {
	name:    [win32.CCHDEVICENAME]u16,
	monitor: win32.HMONITOR,
}

// Call before showing the window and before sizing its renderer. A missing or
// invalid file leaves the ordinary startup window in place.
window_layout_restore :: proc(state: ^Window_Layout_State, hwnd: win32.HWND) -> bool {
	path, _, paths_ok := window_layout_paths()
	loaded := paths_ok && window_layout_load_from_path(state, path)
	if loaded {
		search := Window_Layout_Monitor_Search{name = state.monitor}
		win32.EnumDisplayMonitors(nil, nil, window_layout_find_monitor, win32.LPARAM(uintptr(&search)))
		monitor := search.monitor
		if monitor == nil do monitor = win32.MonitorFromRect(&state.rect, .MONITOR_DEFAULTTONEAREST)
		info := win32.MONITORINFO{cbSize = size_of(win32.MONITORINFO)}
		if monitor != nil && bool(win32.GetMonitorInfoW(monitor, &info)) {
			// Move the still-hidden window wholly onto its target display before
			// asking for its DPI. GetDpiForWindow honors per-monitor v2 awareness;
			// GetDpiForMonitor can give different answers with that context.
			rect := window_layout_fit(state.layout, info.rcWork, state.dpi)
			win32.SetWindowPos(hwnd, nil, rect.left, rect.top, rect.right-rect.left, rect.bottom-rect.top, win32.SWP_NOACTIVATE | win32.SWP_NOZORDER)
			// The first move may synchronously process WM_DPICHANGED. Apply the
			// final fit after its suggested rectangle so saved logical size wins.
			rect = window_layout_fit(state.layout, info.rcWork, win32.GetDpiForWindow(hwnd))
			target := win32.HWND_TOPMOST if state.always_on_top else win32.HWND_NOTOPMOST
			win32.SetWindowPos(hwnd, target, rect.left, rect.top, rect.right-rect.left, rect.bottom-rect.top, win32.SWP_NOACTIVATE)
		}
	}
	window_layout_observe(state, hwnd, false, state.always_on_top)
	return loaded
}

window_layout_find_monitor :: proc "system" (monitor: win32.HMONITOR, dc: win32.HDC, rect: win32.LPRECT, data: win32.LPARAM) -> win32.BOOL {
	context = runtime.default_context()
	search := cast(^Window_Layout_Monitor_Search)uintptr(data)
	info: win32.MONITORINFOEXW
	info.cbSize = size_of(info)
	if bool(win32.GetMonitorInfoW(monitor, cast(^win32.MONITORINFO)&info)) && info.szDevice == search.name {
		search.monitor = monitor
		return false
	}
	return true
}

// Snapshot normal placement even when closing a maximized or minimized window.
// Fullscreen preserves the snapshot taken immediately before entering it.
window_layout_observe :: proc(state: ^Window_Layout_State, hwnd: win32.HWND, fullscreen, always_on_top: bool) {
	if state.always_on_top != always_on_top {
		state.always_on_top = always_on_top
		state.dirty = true
	}
	if fullscreen || hwnd == nil do return
	rect: win32.RECT
	if win32.IsZoomed(hwnd) || win32.IsIconic(hwnd) {
		placement := win32.WINDOWPLACEMENT{length = size_of(win32.WINDOWPLACEMENT)}
		if !bool(win32.GetWindowPlacement(hwnd, &placement)) do return
		info := win32.MONITORINFO{cbSize = size_of(win32.MONITORINFO)}
		monitor := win32.MonitorFromWindow(hwnd, .MONITOR_DEFAULTTONEAREST)
		if monitor == nil || !bool(win32.GetMonitorInfoW(monitor, &info)) do return
		// WINDOWPLACEMENT uses workspace coordinates for this top-level window.
		rect = window_layout_screen_rect(placement.rcNormalPosition, info.rcMonitor, info.rcWork)
	} else if !bool(win32.GetWindowRect(hwnd, &rect)) {
		return
	}
	monitor := win32.MonitorFromRect(&rect, .MONITOR_DEFAULTTONEAREST)
	info: win32.MONITORINFOEXW
	info.cbSize = size_of(info)
	if monitor == nil || !bool(win32.GetMonitorInfoW(monitor, cast(^win32.MONITORINFO)&info)) do return
	current := Window_Layout{
		rect = rect,
		work = info.rcWork,
		monitor = info.szDevice,
		dpi = win32.GetDpiForWindow(hwnd),
		always_on_top = always_on_top,
	}
	if !window_layout_valid(current) do return
	if !state.valid || state.layout != current {
		state.layout = current
		state.valid = true
		state.dirty = true
	}
}

window_layout_screen_rect :: proc(rect, monitor, work: win32.RECT) -> win32.RECT {
	dx, dy := work.left-monitor.left, work.top-monitor.top
	return win32.RECT{rect.left+dx, rect.top+dy, rect.right+dx, rect.bottom+dy}
}

// Preserve logical size and work-area-relative position when a monitor moves or
// changes DPI. Fully contain the window on the current work area after unplugging.
window_layout_fit :: proc(layout: Window_Layout, work: win32.RECT, dpi: u32) -> win32.RECT {
	work_width := max(i64(work.right)-i64(work.left), i64(1))
	work_height := max(i64(work.bottom)-i64(work.top), i64(1))
	source_dpi := i64(max(layout.dpi, u32(1)))
	target_dpi := i64(clamp(dpi, u32(48), u32(960)))
	width := max((i64(layout.rect.right)-i64(layout.rect.left))*target_dpi/source_dpi, i64(MIN_CLIENT_W)*target_dpi/96)
	height := max((i64(layout.rect.bottom)-i64(layout.rect.top))*target_dpi/source_dpi, i64(MIN_CLIENT_H)*target_dpi/96+i64(title_bar_height_for_dpi(u32(target_dpi))))
	// Shrink both dimensions together so an unplugged 4K monitor does not change
	// the saved aspect ratio or put the title bar outside the remaining screen.
	if width > work_width {
		height = max(height*work_width/width, i64(1))
		width = work_width
	}
	if height > work_height {
		width = max(width*work_height/height, i64(1))
		height = work_height
	}
	x := i64(work.left)+(i64(layout.rect.left)-i64(layout.work.left))*target_dpi/source_dpi
	y := i64(work.top)+(i64(layout.rect.top)-i64(layout.work.top))*target_dpi/source_dpi
	x = clamp(x, i64(work.left), i64(work.right)-width)
	y = clamp(y, i64(work.top), i64(work.bottom)-height)
	return win32.RECT{i32(x), i32(y), i32(x+width), i32(y+height)}
}

window_layout_valid :: proc(layout: Window_Layout) -> bool {
	if layout.dpi < 48 || layout.dpi > 960 do return false
	rects := [2]win32.RECT{layout.rect, layout.work}
	for rect in rects {
		if rect.left < -WINDOW_LAYOUT_MAX_COORD || rect.top < -WINDOW_LAYOUT_MAX_COORD ||
		   rect.right > WINDOW_LAYOUT_MAX_COORD || rect.bottom > WINDOW_LAYOUT_MAX_COORD ||
		   rect.right <= rect.left || rect.bottom <= rect.top {
			return false
		}
	}
	if layout.monitor[0] == 0 || layout.monitor[len(layout.monitor)-1] != 0 do return false
	for ch in layout.monitor {
		if ch == 0 do break
		if ch < 32 || ch > 126 do return false
	}
	return true
}

window_layout_paths :: proc() -> (path, temp_path: string, ok: bool) {
	directory, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return "", "", false
	return window_layout_paths_for_directory(directory, os.get_pid())
}

window_layout_paths_for_directory :: proc(directory: string, process_id: int) -> (path, temp_path: string, ok: bool) {
	settings_path, err := filepath.join([]string{directory, WINDOW_LAYOUT_FILE}, context.temp_allocator)
	if err != nil do return "", "", false
	temp_name := fmt.aprintf("elga-window.ini.%d.tmp", process_id, allocator = context.temp_allocator)
	settings_temp_path, temp_err := filepath.join([]string{directory, temp_name}, context.temp_allocator)
	if temp_err != nil do return "", "", false
	return settings_path, settings_temp_path, true
}

window_layout_load_from_path :: proc(state: ^Window_Layout_State, path: string) -> bool {
	file, err := os.open(path)
	if err != nil do return false
	defer os.close(file)
	size, size_error := os.file_size(file)
	if size_error != nil || size <= 0 || size > 4096 do return false
	buffer: [4096]byte
	_, read_error := os.read_full(file, buffer[:int(size)])
	if read_error != nil do return false
	layout, ok := window_layout_parse(string(buffer[:int(size)]))
	if !ok do return false
	state^ = Window_Layout_State{layout = layout, valid = true}
	return true
}

window_layout_save :: proc(state: ^Window_Layout_State) -> bool {
	if !state.dirty do return !state.save_failed
	path, temp_path, ok := window_layout_paths()
	if !ok {
		state.save_failed = true
		return false
	}
	return window_layout_save_to_paths(state, path, temp_path)
}

window_layout_save_to_paths :: proc(state: ^Window_Layout_State, path, temp_path: string) -> bool {
	if !state.dirty do return !state.save_failed
	buffer: [1024]byte
	if !state.valid || !window_layout_valid(state.layout) {
		state.save_failed = true
		return false
	}
	settings := window_layout_format(buffer[:], state.layout)
	if os.write_entire_file(temp_path, settings) != nil || os.rename(temp_path, path) != nil {
		_ = os.remove(temp_path)
		state.save_failed = true
		return false
	}
	state.dirty = false
	state.save_failed = false
	return true
}

window_layout_format :: proc(buffer: []byte, layout: Window_Layout) -> string {
	monitor_buffer: [win32.CCHDEVICENAME]byte
	monitor_len := 0
	for ch in layout.monitor {
		if ch == 0 do break
		monitor_buffer[monitor_len] = byte(ch)
		monitor_len += 1
	}
	return fmt.bprintf(buffer,
		"[window]\r\nversion=1\r\nx=%d\r\ny=%d\r\nwidth=%d\r\nheight=%d\r\nwork_x=%d\r\nwork_y=%d\r\nwork_width=%d\r\nwork_height=%d\r\ndpi=%d\r\nalways_on_top=%d\r\nmonitor=%s\r\n",
		layout.rect.left, layout.rect.top, layout.rect.right-layout.rect.left, layout.rect.bottom-layout.rect.top,
		layout.work.left, layout.work.top, layout.work.right-layout.work.left, layout.work.bottom-layout.work.top,
		layout.dpi, int(layout.always_on_top), string(monitor_buffer[:monitor_len]))
}

window_layout_parse :: proc(data: string) -> (layout: Window_Layout, ok: bool) {
	if len(data) > 4096 do return {}, false
	keys := [12]string{"version", "x", "y", "width", "height", "work_x", "work_y", "work_width", "work_height", "dpi", "always_on_top", "monitor"}
	values: [11]i32
	seen: u32
	in_section := false
	remaining := data
	for raw_line in strings.split_lines_iterator(&remaining) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || line[0] == ';' || line[0] == '#' do continue
		if line[0] == '[' {
			in_section = line == "[window]"
			continue
		}
		if !in_section do continue
		equals := strings.index_byte(line, '=')
		if equals < 0 do return {}, false
		key := strings.trim_space(line[:equals])
		value := strings.trim_space(line[equals+1:])
		for expected, index in keys {
			if key != expected do continue
			bit := u32(1)<<u32(index)
			if seen & bit != 0 do return {}, false
			seen |= bit
			if index == 11 {
				if len(value) == 0 || len(value) >= len(layout.monitor) do return {}, false
				for ch, char_index in transmute([]byte)value {
					if ch < 32 || ch > 126 do return {}, false
					layout.monitor[char_index] = u16(ch)
				}
			} else {
				parsed, valid := strconv.parse_int(value, 10)
				if !valid || parsed < -WINDOW_LAYOUT_MAX_COORD || parsed > WINDOW_LAYOUT_MAX_COORD do return {}, false
				values[index] = i32(parsed)
			}
			break
		}
	}
	if seen != (u32(1)<<12)-1 || values[0] != 1 || values[3] <= 0 || values[4] <= 0 ||
	   values[7] <= 0 || values[8] <= 0 || values[9] < 48 || values[9] > 960 ||
	   (values[10] != 0 && values[10] != 1) {
		return {}, false
	}
	layout.rect = win32.RECT{values[1], values[2], values[1]+values[3], values[2]+values[4]}
	layout.work = win32.RECT{values[5], values[6], values[5]+values[7], values[6]+values[8]}
	layout.dpi = u32(values[9])
	layout.always_on_top = values[10] == 1
	return layout, window_layout_valid(layout)
}
