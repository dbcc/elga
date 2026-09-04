package main

import "core:testing"
import win32 "core:sys/windows"

@(test)
window_resize_edges_test :: proc(t: ^testing.T) {
	bottom := win32.RECT{100, 100, 740, 550}
	enforce_16_9_for_dpi(&bottom, win32.WMSZ_BOTTOM, 96)
	testing.expect_value(t, bottom, win32.RECT{100, 100, 900, 550})
	top := win32.RECT{100, 10, 740, 460}
	enforce_16_9_for_dpi(&top, win32.WMSZ_TOP, 96)
	testing.expect_value(t, top, win32.RECT{100, 10, 900, 460})
	right := win32.RECT{100, 100, 900, 460}
	enforce_16_9_for_dpi(&right, win32.WMSZ_RIGHT, 96)
	testing.expect_value(t, right, win32.RECT{100, 100, 900, 550})
	left := win32.RECT{20, 100, 740, 460}
	enforce_16_9_for_dpi(&left, win32.WMSZ_LEFT, 96)
	testing.expect_value(t, left, win32.RECT{20, 100, 740, 505})
	minimum := win32.RECT{100, 100, 200, 200}
	enforce_16_9_for_dpi(&minimum, win32.WMSZ_BOTTOMRIGHT, 192)
	testing.expect_value(t, minimum, win32.RECT{100, 100, 740, 460})
}
