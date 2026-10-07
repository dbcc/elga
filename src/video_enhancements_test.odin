package main

import "core:os"
import "core:path/filepath"
import "core:testing"
import "core:sync"

@(test)
video_preferences_roundtrip_test :: proc(t: ^testing.T) {
	testing.expect_value(t, video_preferences_parse(""), Video_Preferences{})
	testing.expect_value(t, video_preferences_parse("[audio]\nsuper_resolution=1\nframe_generation=1\ngame_30_fps=1"), Video_Preferences{})
	testing.expect_value(t, video_preferences_parse("[video]\nsuper_resolution=invalid\nframe_generation=-1\ngame_30_fps=invalid"), Video_Preferences{})
	testing.expect_value(t, video_preferences_parse("[video]\nframe_generation=1"), Video_Preferences{frame_generation = true})
	directory, err := os.make_directory_temp("", "elga-video-test-*", context.temp_allocator)
	if !testing.expect(t, err == nil) do return
	path, _ := filepath.join([]string{directory, "video.ini"}, context.temp_allocator)
	temporary, _ := filepath.join([]string{directory, "video.tmp"}, context.temp_allocator)
	defer { _ = os.remove(path); _ = os.remove(temporary); _ = os.remove(directory) }
	for mask in 0..<8 {
		p := Video_Preferences{mask&1 != 0, mask&2 != 0, mask&4 != 0}
		testing.expect(t, video_preferences_save_to(p, path, temporary))
		data, read_error := os.read_entire_file(path, context.temp_allocator)
		testing.expect(t, read_error == nil)
		testing.expect_value(t, video_preferences_parse(string(data)), p)
	}
	// An invalid destination must not replace the last good preference file.
	testing.expect(t, !video_preferences_save_to({true, true, true}, directory, temporary))
	data, read_error := os.read_entire_file(path, context.temp_allocator)
	testing.expect(t, read_error == nil)
	testing.expect_value(t, video_preferences_parse(string(data)), Video_Preferences{true, true, true})
}

@(test)
video_optional_backend_and_abi_test :: proc(t: ^testing.T) {
	// Match the published x64 C ABI, including 64-bit alignment/padding.
	testing.expect_value(t, size_of(Video_API), 64)
	testing.expect_value(t, size_of(Video_Config), 48)
	testing.expect_value(t, size_of(Video_Frame), 32)
	testing.expect_value(t, size_of(Video_Output), 48)
	testing.expect_value(t, size_of(Video_Status), 80)
	testing.expect(t, !video_backend_valid({}))
	testing.expect(t, !video_backend_valid({version = 999, size = size_of(Video_API)}))
	testing.expect(t, !video_backend_valid({version = 1, size = size_of(Video_API)}))
	testing.expect(t, !video_backend_valid({version = 2, size = size_of(Video_API)}))
	r: Renderer
	r.enhancements.preferences.game_30_fps = true
	// Both off must neither load a DLL nor allocate processing resources.
	video_enhancements_prepare(&r)
	testing.expect(t, !r.enhancements.load_attempted)
	testing.expect(t, r.enhancements.session == nil && r.enhancements.timer == nil)
	r.enhancements.preferences = {true, true, true}
	// Model an absent add-on without depending on what the developer installed.
	r.enhancements.load_attempted = true
	r.enhancements.caps = {vsr_reason = .Runtime, fruc_reason = .Runtime}
	video_enhancements_prepare(&r)
	testing.expect_value(t, r.enhancements.status.vsr_state, Video_Effect_State.Unavailable)
	testing.expect_value(t, r.enhancements.status.fruc_state, Video_Effect_State.Unavailable)
	testing.expect_value(t, r.enhancements.preferences, Video_Preferences{true, true, true})
	r.enhancements.cached.generation = 10
	r.enhancements.status.delay = 666667
	video_enhancements_reset(&r)
	testing.expect_value(t, r.enhancements.cached.token, u64(0))
	testing.expect_value(t, r.enhancements.status.delay, i64(0))
	testing.expect_value(t, r.enhancements.generation, u32(1))
}

@(test)
audio_video_delay_timing_and_reset_test :: proc(t: ^testing.T) {
	d: Audio_Video_Delay
	input := [8]f32{1, -1, 2, -2, 3, -3, 4, -4}
	output: [8]f32
	testing.expect(t, !audio_video_delay_samples(&d, output[:], input[:]))
	// A two-frame ring delays both channels equally; suppress the independent
	// fade for this exact sample-order assertion.
	d.requested, d.applied = 2, 2
	testing.expect(t, audio_video_delay_samples(&d, output[:], input[:]))
	testing.expect_value(t, output, [8]f32{0, 0, 0, 0, 1, -1, 2, -2})
	testing.expect(t, audio_video_delay_samples(&d, output[:], input[:]))
	testing.expect_value(t, output, [8]f32{3, -3, 4, -4, 1, -1, 2, -2})
	// Reset must flush even when the requested delay is unchanged between callbacks.
	sync.atomic_add_explicit(&d.reset_requested, 1, .Release)
	input = {}
	testing.expect(t, audio_video_delay_samples(&d, output[:], input[:]))
	testing.expect_value(t, output, [8]f32{})
	// Changing the delay flushes the ring and fades in, never replaying old data.
	sync.atomic_store_explicit(&d.requested, 3, .Release)
	input = {}
	testing.expect(t, audio_video_delay_samples(&d, output[:], input[:]))
	testing.expect_value(t, output, [8]f32{})
	sync.atomic_store_explicit(&d.requested, 0, .Release)
	for _ in 0..<AUDIO_VIDEO_FADE_FRAMES do audio_video_delay_samples(&d, output[:], input[:])
	testing.expect(t, !audio_video_delay_samples(&d, output[:], input[:]))
	a: Audio_State
	audio_set_video_delay(&a, 666667)
	testing.expect_value(t, sync.atomic_load_explicit(&a.video_delay.requested, .Acquire), u32(3200))
	audio_set_video_delay(&a, -1)
	testing.expect_value(t, a.video_delay.requested, u32(0))
}
