package main

import "core:sync"
import "core:testing"

@(test)
audio_volume_samples_test :: proc(t: ^testing.T) {
	input := [4]f32{1, -1, 0.5, -0.5}
	output: [4]f32

	audio_apply_volume_samples(output[:], input[:], 100, false)
	testing.expect_value(t, output, input)

	audio_apply_volume_samples(output[:], input[:], 50, false)
	testing.expect_value(t, output, [4]f32{0.5, -0.5, 0.25, -0.25})

	audio_apply_volume_samples(output[:], input[:], 0, false)
	testing.expect_value(t, output, [4]f32{})

	audio_apply_volume_samples(output[:], input[:], 75, true)
	testing.expect_value(t, output, [4]f32{})
}

@(test)
audio_volume_change_unmutes_test :: proc(t: ^testing.T) {
	audio: Audio_State
	sync.atomic_store_explicit(&audio.volume_percent, 40, .Relaxed)
	audio_set_muted(&audio, true)
	audio_set_volume_percent(&audio, 65)
	testing.expect_value(t, audio_get_volume_percent(&audio), u32(65))
	testing.expect(t, !audio_is_muted(&audio))

	audio_set_muted(&audio, true)
	audio_set_volume_percent(&audio, 0)
	testing.expect_value(t, audio_get_volume_percent(&audio), u32(0))
	testing.expect(t, !audio_is_muted(&audio))

	audio_set_muted(&audio, true)
	audio_set_volume_percent(&audio, 0)
	testing.expect_value(t, audio_get_volume_percent(&audio), u32(0))
	testing.expect(t, audio_is_muted(&audio))
}

@(test)
audio_volume_settings_test :: proc(t: ^testing.T) {
	percent, ok := audio_parse_volume_settings("[audio]\r\nvolume_percent=75\r\n")
	testing.expect(t, ok)
	testing.expect_value(t, percent, u32(75))

	percent, ok = audio_parse_volume_settings("")
	testing.expect(t, !ok)
	testing.expect_value(t, percent, u32(AUDIO_VOLUME_DEFAULT))

	percent, ok = audio_parse_volume_settings("[video]\nvolume_percent=25\n")
	testing.expect(t, !ok)
	testing.expect_value(t, percent, u32(AUDIO_VOLUME_DEFAULT))

	percent, ok = audio_parse_volume_settings("[audio]\nvolume_percent=101\n")
	testing.expect(t, !ok)
	testing.expect_value(t, percent, u32(AUDIO_VOLUME_DEFAULT))

	percent, ok = audio_parse_volume_settings("[audio]\nvolume_percent=-1\n")
	testing.expect(t, !ok)
	testing.expect_value(t, percent, u32(AUDIO_VOLUME_DEFAULT))

	percent, ok = audio_parse_volume_settings("[audio]\nvolume_percent=quiet\n")
	testing.expect(t, !ok)
	testing.expect_value(t, percent, u32(AUDIO_VOLUME_DEFAULT))

	buffer: [64]byte
	serialized := audio_format_volume_settings(buffer[:], 35)
	testing.expect_value(t, serialized, "[audio]\r\nvolume_percent=35\r\n")
	percent, ok = audio_parse_volume_settings(serialized)
	testing.expect(t, ok)
	testing.expect_value(t, percent, u32(35))

	testing.expect(t, !audio_write_volume_settings("", "", 50))
}
