package main

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"

// Settings files live beside the executable so the app stays portable.
settings_paths :: proc(file_name: string) -> (path, temp_path: string, ok: bool) {
	directory, err := os.get_executable_directory(context.temp_allocator)
	if err != nil do return
	return settings_paths_for_directory(directory, file_name, os.get_pid())
}

// The temporary name includes the process id so concurrent instances never
// write the same partial file.
settings_paths_for_directory :: proc(directory, file_name: string, process_id: int) -> (path, temp_path: string, ok: bool) {
	path_error, temp_error: runtime.Allocator_Error
	path, path_error = filepath.join({directory, file_name}, context.temp_allocator)
	temp_name := fmt.tprintf("%s.%d.tmp", file_name, process_id)
	temp_path, temp_error = filepath.join({directory, temp_name}, context.temp_allocator)
	if path_error != nil || temp_error != nil do return "", "", false
	return path, temp_path, true
}

// Replaces path via a rename so a crash never leaves a truncated file.
settings_write :: proc(path, temp_path, data: string) -> bool {
	if os.write_entire_file(temp_path, data) == nil && os.rename(temp_path, path) == nil do return true
	_ = os.remove(temp_path)
	return false
}

// Iterates the key=value lines of one INI section, skipping blank lines and
// comments. A line without '=' yields an empty key.
Ini_Iterator :: struct {
	data:       string,
	section:    string,
	in_section: bool,
}

ini_next :: proc(it: ^Ini_Iterator) -> (key, value: string, ok: bool) {
	for raw_line in strings.split_lines_iterator(&it.data) {
		line := strings.trim_space(raw_line)
		if len(line) == 0 || line[0] == ';' || line[0] == '#' do continue
		if line[0] == '[' {
			it.in_section = line == it.section
			continue
		}
		if !it.in_section do continue
		equals := strings.index_byte(line, '=')
		if equals < 0 do return "", line, true
		return strings.trim_space(line[:equals]), strings.trim_space(line[equals+1:]), true
	}
	return "", "", false
}
