package main

import "core:sync"

// 250 ms maximum, preallocated; all ring state belongs solely to the callback.
// The UI only publishes the requested length. No allocation or locking occurs
// in WASAPI's real-time callback, and zero delay bypasses the ring entirely.
AUDIO_VIDEO_DELAY_MAX :: AUDIO_SAMPLE_RATE/4
AUDIO_VIDEO_FADE_FRAMES :: AUDIO_SAMPLE_RATE/200
Audio_Video_Delay :: struct {
	requested: u32,
	reset_requested, reset_applied: u32,
	applied, cursor, filled, fade: u32,
	samples: [AUDIO_VIDEO_DELAY_MAX*AUDIO_CHANNELS]f32,
}

audio_reset_video_delay :: proc(a: ^Audio_State) {
	sync.atomic_store_explicit(&a.video_delay.requested, 0, .Release)
	// A brief 0 -> same-delay transition can happen between audio callbacks.
	// A generation makes that flush observable even if the callback misses 0.
	sync.atomic_add_explicit(&a.video_delay.reset_requested, 1, .Release)
}

audio_set_video_delay :: proc(a: ^Audio_State, delay_100ns: i64) {
	frames := u32(clamp(delay_100ns*AUDIO_SAMPLE_RATE/10_000_000, 0, AUDIO_VIDEO_DELAY_MAX))
	sync.atomic_store_explicit(&a.video_delay.requested, frames, .Release)
}

audio_video_delay_samples :: proc "contextless" (d: ^Audio_Video_Delay, output, input: []f32) -> bool {
	requested := min(sync.atomic_load_explicit(&d.requested, .Acquire), AUDIO_VIDEO_DELAY_MAX)
	reset := sync.atomic_load_explicit(&d.reset_requested, .Acquire)
	if requested != d.applied || reset != d.reset_applied {
		d.reset_applied = reset
		d.applied = requested
		d.cursor, d.filled, d.fade = 0, 0, AUDIO_VIDEO_FADE_FRAMES
	}
	if requested == 0 && d.fade == 0 do return false
	for i := 0; i < min(len(input), len(output)); i += AUDIO_CHANNELS {
		gain := f32(1)
		if d.fade != 0 && (requested == 0 || d.filled >= requested) {
			gain = 1-f32(d.fade)/AUDIO_VIDEO_FADE_FRAMES
			d.fade -= 1
		}
		for channel in 0..<AUDIO_CHANNELS {
			if i+channel >= len(output) || i+channel >= len(input) do break
			value := input[i+channel]
			if requested != 0 {
				index := int(d.cursor)*AUDIO_CHANNELS+channel
				value = d.samples[index] if d.filled >= requested else 0
				d.samples[index] = input[i+channel]
			}
			output[i+channel] = value*gain
		}
		if requested != 0 {
			d.cursor += 1
			if d.cursor == requested do d.cursor = 0
			d.filled = min(d.filled+1, requested)
		}
	}
	return true
}
