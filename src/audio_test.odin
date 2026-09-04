package main

import "core:os"
import "core:path/filepath"
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

	volumes := []u32{0, 50, 100}
	for volume in volumes {
		output = {9, 9, 9, 9}
		audio_apply_volume_samples(output[:], input[:2], volume, false)
		testing.expect_value(t, output[2], f32(0))
		testing.expect_value(t, output[3], f32(0))
	}
	output = {9, 9, 9, 9}
	audio_apply_volume_samples(output[:], nil, 100, false)
	testing.expect_value(t, output, [4]f32{})
}

@(test)
audio_output_selection_noop_test :: proc(t: ^testing.T) {
	audio := Audio_State{context_ready = true, device_ready = true, selected_output = -1}
	// No real device exists in this fixture: these paths must not touch WASAPI.
	testing.expect(t, audio_select_output(&audio, -1))
	testing.expect(t, !audio_select_output(&audio, -2))
	testing.expect(t, !audio_select_output(&audio, 0))
	testing.expect(t, audio.device_ready)
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

	temp_directory, temp_error := os.make_directory_temp("", "elga-audio-test-*", context.temp_allocator)
	testing.expect(t, temp_error == nil)
	if temp_error != nil do return
	settings_path, temp_path, paths_ok := audio_settings_paths_for_directory(temp_directory, 1001)
	testing.expect(t, paths_ok)
	_, second_temp_path, second_paths_ok := audio_settings_paths_for_directory(temp_directory, 1002)
	testing.expect(t, second_paths_ok)
	testing.expect(t, temp_path != second_temp_path)
	blocker_path, blocker_path_error := filepath.join([]string{temp_directory, "not-a-directory"}, context.temp_allocator)
	testing.expect(t, blocker_path_error == nil)
	bad_settings_path, bad_settings_path_error := filepath.join([]string{blocker_path, AUDIO_SETTINGS_FILE}, context.temp_allocator)
	testing.expect(t, bad_settings_path_error == nil)
	bad_temp_path, bad_temp_path_error := filepath.join([]string{blocker_path, "settings.tmp"}, context.temp_allocator)
	testing.expect(t, bad_temp_path_error == nil)
	defer {
		_ = os.remove(settings_path)
		_ = os.remove(temp_path)
		_ = os.remove(second_temp_path)
		_ = os.remove(blocker_path)
		_ = os.remove(temp_directory)
	}

	saved: Audio_State
	sync.atomic_store_explicit(&saved.volume_percent, 42, .Relaxed)
	saved.settings_dirty = true
	testing.expect(t, audio_save_settings_to_paths(&saved, settings_path, temp_path))
	testing.expect(t, !saved.settings_dirty)
	testing.expect(t, !saved.settings_save_failed)

	loaded: Audio_State
	sync.atomic_store_explicit(&loaded.volume_percent, AUDIO_VOLUME_DEFAULT, .Relaxed)
	testing.expect(t, audio_load_settings_from_path(&loaded, settings_path))
	testing.expect_value(t, audio_get_volume_percent(&loaded), u32(42))

	testing.expect(t, os.write_entire_file(blocker_path, "block") == nil)
	failed: Audio_State
	sync.atomic_store_explicit(&failed.volume_percent, 77, .Relaxed)
	failed.settings_dirty = true
	testing.expect(t, !audio_save_settings_to_paths(&failed, bad_settings_path, bad_temp_path))
	testing.expect_value(t, audio_get_volume_percent(&failed), u32(77))
	testing.expect(t, failed.settings_dirty)
	testing.expect(t, failed.settings_save_failed)
	testing.expect(t, audio_save_settings_to_paths(&failed, settings_path, temp_path))
	testing.expect(t, !failed.settings_dirty)
	testing.expect(t, !failed.settings_save_failed)
	testing.expect(t, audio_load_settings_from_path(&loaded, settings_path))
	testing.expect_value(t, audio_get_volume_percent(&loaded), u32(77))

	missing: Audio_State
	sync.atomic_store_explicit(&missing.volume_percent, AUDIO_VOLUME_DEFAULT, .Relaxed)
	testing.expect(t, !audio_load_settings_from_path(&missing, second_temp_path))
	testing.expect_value(t, audio_get_volume_percent(&missing), u32(AUDIO_VOLUME_DEFAULT))
}
