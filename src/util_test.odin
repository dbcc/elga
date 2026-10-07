package main

import "core:testing"
import win32 "core:sys/windows"

@(test)
contains_ascii_fold_test :: proc(t: ^testing.T) {
	// Audio endpoints report UTF-8 names; Media Foundation reports UTF-16.
	testing.expect(t, contains_ascii_fold(transmute([]u8)string("Elgato 4K X Audio"), "elgato 4k x"))
	testing.expect(t, contains_ascii_fold(transmute([]u8)string("HDMI (4K X)"), "4k x"))
	testing.expect(t, !contains_ascii_fold(transmute([]u8)string("4K"), "4k x"))
	testing.expect(t, contains_ascii_fold(transmute([]u8)string(""), ""))
	link := win32.utf8_to_utf16(`\\?\USB#VID_0FD9&PID_009C&MI_00`, context.temp_allocator)
	testing.expect(t, contains_ascii_fold(link, "vid_0fd9"))
	testing.expect(t, contains_ascii_fold(link, "pid_009c"))
	testing.expect(t, !contains_ascii_fold(link, "pid_009b"))
}
