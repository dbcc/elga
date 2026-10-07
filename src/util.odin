package main

import "core:fmt"
import win32 "core:sys/windows"

failed :: proc(hr: win32.HRESULT) -> bool {
	return win32.FAILED(hr)
}

// Logs a failed HRESULT with the operation that produced it.
check :: proc(hr: win32.HRESULT, operation: string) -> bool {
	if !failed(hr) do return true
	fmt.eprintf("%s failed: 0x%08x\n", operation, u32(hr))
	return false
}

com_release :: proc(p: $T) {
	if p != nil {
		unknown := cast(^win32.IUnknown)p
		unknown.Release(unknown)
	}
}

// Releases an owned interface field and clears it.
com_clear :: proc(p: ^$T) {
	com_release(p^)
	p^ = nil
}

// Case-insensitive ASCII search over UTF-8 or UTF-16 text. Needles are lowercase.
contains_ascii_fold :: proc(text: []$T, needle: string) -> bool {
	outer: for start in 0..=len(text)-len(needle) {
		for j in 0..<len(needle) {
			c := text[start+j]
			if c >= 'A' && c <= 'Z' do c += 'a'-'A'
			if c != T(needle[j]) do continue outer
		}
		return true
	}
	return false
}
