package main

import "core:testing"
import win32 "core:sys/windows"

@(test)
window_resize_edges_test :: proc(t: ^testing.T) {
	bottom := win32.RECT{100, 100, 740, 550}
	enforce_16_9_for_dpi(&bottom, win32.WMSZ_BOTTOM, 96)
	testing.expect_value(t, bottom, win32.RECT{100, 100, 825, 550})
	top := win32.RECT{100, 10, 740, 460}
	enforce_16_9_for_dpi(&top, win32.WMSZ_TOP, 96)
	testing.expect_value(t, top, win32.RECT{100, 10, 825, 460})
	right := win32.RECT{100, 100, 900, 460}
	enforce_16_9_for_dpi(&right, win32.WMSZ_RIGHT, 96)
	testing.expect_value(t, right, win32.RECT{100, 100, 900, 592})
	left := win32.RECT{20, 100, 740, 460}
	enforce_16_9_for_dpi(&left, win32.WMSZ_LEFT, 96)
	testing.expect_value(t, left, win32.RECT{20, 100, 740, 547})
	minimum := win32.RECT{100, 100, 200, 200}
	enforce_16_9_for_dpi(&minimum, win32.WMSZ_BOTTOMRIGHT, 192)
	testing.expect_value(t, minimum, win32.RECT{100, 100, 740, 544})
}

@(test)
window_video_aspect_excludes_title_bar_test :: proc(t: ^testing.T) {
	for dpi in ([4]u32{96, 120, 144, 192}) {
		width := i32(1280*dpi/96)
		video_height := width*9/16
		bar_height := title_bar_height_for_dpi(dpi)
		for edge in ([8]u32{
			win32.WMSZ_LEFT, win32.WMSZ_RIGHT, win32.WMSZ_TOP, win32.WMSZ_BOTTOM,
			win32.WMSZ_TOPLEFT, win32.WMSZ_TOPRIGHT, win32.WMSZ_BOTTOMLEFT, win32.WMSZ_BOTTOMRIGHT,
		}) {
			rect := win32.RECT{100, 100, 100+width, 100+video_height+bar_height}
			expected := rect
			enforce_16_9_for_dpi(&rect, edge, dpi)
			testing.expect_value(t, rect, expected)
		}
	}
	testing.expect_value(t, title_bar_height_for_dpi(120), i32(53))
}
