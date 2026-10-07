# Optional video enhancements

Settings > Video enhancements contains independent **RTX Video Super Resolution**
and **Frame generation (2x)** toggles, both off initially. Preferences persist in
`elga-video.ini` beside the executable. These are video APIs, not game DLSS.

## Validation status

The backend now builds against the official RTX Video SDK 1.1.0 and Optical Flow
SDK 5.0.7. Real VSR and NvOFFRUC inference have passed generated-motion GPU tests
on an RTX 5090 with driver 616.92. The FRUC adapter uses the official `NvOFFRUC.h`,
two alternating input textures plus one output, explicit fence wait/signal values,
and the SDK's frame-repetition output flag. SDK-free transport tests remain separate.

Live Switch HDMI image quality, audio alignment, scene cuts, HUD artifacts,
HDR-source behavior, and 4K combined throughput remain unverified. These tests
exercise the production backend and GPU readback, not a physical display or capture
card. They do not establish support or performance for other GPU/driver combinations.

Measured on 2026-09-17, RTX 5090 / driver 616.92, using three-second scrolling
texture sequences after initialization. All cases had zero reported deadline
misses. Output counts exclude frames still buffered at the end of the run.

| Case | Original / generated outputs | Mean worker time |
| --- | --- | --- |
| 720p to 1080p VSR, 60 FPS | 180 / 0 | 0.37 ms |
| 1080p to 4K VSR, 60 FPS | 180 / 0 | 0.36 ms |
| 720p 30 to 60 | 88 / 88 | 3.23 ms |
| 720p 60 to 120 | 178 / 178 | 3.22 ms |
| 1080p 30 to 60 | 88 / 88 | 4.58 ms |
| 1080p 60 to 120 | 178 / 178 | 4.81 ms |
| Manual 30-in-60, 720p to 1080p combined | 88 / 88 | 3.61 ms |
| Manual 30-in-60, 1080p to 1440p combined | 88 / 88 | 4.68 ms |
| Manual 30-in-60, 4K frame generation only | 88 / 88 | 13.24 ms |

Worker time measures host processing including FRUC synchronization; VSR submits
GPU work asynchronously, so its row is not an isolated GPU execution measurement.
Automatic 30-in-60 detection produced 120 originals / 56 generated frames,
including the initial capture-rate observation window. Two timestamp restarts
produced 86 originals / 84 generated frames and recovered without SDK errors.
History resets prime the next input using `bSkipWarp`, while a separate monotonic
SDK timestamp prevents capture timestamp restarts from contaminating interpolation.
An early low-motion test caused NvOFFRUC to repeat output; those frames were
correctly excluded from generated counters. Actual games may behave similarly.

A live 4K60 NV12 Switch capture with the manual 30 FPS override exposed occasional
capture drops that previously flushed interpolation and audio history. After the
short-gap fix, a 40-second moving-content observation held approximately 30
original plus 30 generated FPS, with zero reported enhancement misses and no
history resets after initialization despite capture drops. This is a timing-log
observation, not full visual or audio-alignment acceptance.

## Build and installation

The normal `build.ps1` remains SDK-free. With CMake and Visual Studio C++ tools:

```powershell
# Build transport and run synthetic tests; installs nothing.
.\build-video.ps1

# Extract the specified official NVIDIA SDKs first.
.\build-video.ps1 -RtxVideoSdk 'C:\SDKs\rtx_video_sdk_v1.1.0' `
    -OpticalFlowSdk 'C:\SDKs\optical_flow_sdk_5.0.7' -Package -ValidateHardware
```

`native/video/sdk-versions.json` records targeted versions and official download
links. Supply these exact versions; changing them requires renewed acceptance.
The package manifest records actual file hashes, not proof that an arbitrary
SDK directory matches the named version.

Packaging creates a fresh `build/video-package-*/enhancements/nvidia` folder.
After hardware acceptance, copy its `enhancements` folder beside the executable.
Include SDK-supplied notices and permitted dependencies. Restart Elga after
changing runtime files. `-NgxAppId` supplies the registered NVIDIA release ID;
the default is development ID 0. Never ship `elga-video-test.dll` as an add-on.

The add-on contains `elga-video.dll`, `nvngx_vsr.dll`, `NvOFFRUC.dll`,
`cudart64_110.dll`, and SDK notices. NvOFFRUC also needs the Microsoft Visual C++
2015–2022 x64 runtime in Windows; it was already installed on the validation PC.
The CUDA toolkit is not required to run the packaged add-on. `-ValidateHardware`
requires both SDKs and runs `video-nvidia-test.exe` against the packaged production
DLL. The executable also accepts an optional zero-based case index for diagnosis.
Set `ELGA_VIDEO_DIAGNOSTICS=1` for SDK initialization/error logging and a timing
sample every two seconds to stderr (capture/output rates, worker time, missed
deadlines, history resets, capture drops, and frame-generation state/delay).

Either SDK can be built independently. Missing components show **Unavailable**
without disabling the other feature. Libraries load only from the explicit
add-on folder and System32; bundled NVIDIA DLLs require valid NVIDIA signatures.
Worker-side feature creation determines hardware/driver support. If Windows
selected another GPU, select NVIDIA for Elga in Windows graphics settings and
restart; Elga does not copy frames between adapters.

## Behavior

- VSR scales to the video viewport, capped at 4K, and bypasses native-size or
  smaller viewports. Quality is Medium (level 2): SDK headers expose discrete
  levels rather than an automatic default. HDR conversion is disabled.
- Frame generation runs at capture resolution, followed by VSR when enabled.
  Display refresh must support twice the established source cadence, with a
  0.5 Hz fractional-rate tolerance.
- Exact GPU comparisons recognize stable 2-, 3-, and 4-frame repeat runs over
  one second of moving content. Static scenes retain the established cadence;
  noisy or ambiguous content uses capture cadence. Clean 30 FPS content carried
  in repeated 60 Hz frames can therefore target 60 FPS.
- **Game frame rate: 30 FPS** is a remembered override under Settings > Video
  enhancements. Enable it for a known 30 FPS game carried in a 60 FPS signal
  (for example, Switch 2). While frame generation is active, it selects source
  frames at 30 FPS and interpolates to 60 FPS without requiring identical repeats.
  A 59.94 Hz capture is sampled at 29.97 FPS. Selection uses capture timestamps;
  native 30 FPS input is not halved again. It assumes the game runs at 30 FPS;
  fluctuating game rates or uneven repeats can still cause judder. Off restores
  automatic cadence detection. The override defaults off and does nothing when
  frame generation is off or unavailable. Changing it resets video/audio history.
  Short capture gaps preserve the sampling phase and audio delay. A replacement
  HDMI repeat uses its original game-frame time slot. Missing an entire game frame
  primes interpolation again without flushing valid queued output; backward
  timestamps and gaps over three game periods still reset the playback clock.
  Unselected repeats skip the worker's BGRA-to-RGBA conversion.
- Interpolation adds two source periods: approximately 33 ms at 60 FPS or 67 ms
  at 30 FPS. Audio gets the same added delay, capped at 250 ms. Slower modes are
  bypassed. This compensates the new video buffer, not an unknown pre-existing
  capture-card audio/video offset.
- Three input slots and up to eight output slots bound memory and backlog.
  SR-only processing uses three output slots, saving five output textures
  (about 158 MiB at 4K). Comparison/history textures are omitted for SR-only and
  manual-30 sessions. Exact comparisons reduce each 16x16 pixel group before
  updating the shared result, avoiding one global atomic per changed pixel. Capture
  callbacks never wait for inference. Images remain on the GPU; only the
  four-byte duplicate-comparison result is read back.
- Thirty consecutive processing intervals over budget pause VSR first, or FRUC
  when VSR is inactive. Toggle off/on to retry. SDK errors fall back immediately.
- Configuration generations reject stale results. Repaints reuse cached output;
  they do not count as new frames. Elga's UI is composed afterward, but the
  console's own HUD is baked into video and can show interpolation artifacts.
- Screenshots retain native-source behavior. Turning both effects off releases
  worker GPU resources asynchronously and removes the additional audio delay.

## ABI and ownership

`native/video/video_api.h` defines x64 ABI version 3; Odin tests check structure
sizes. `configure` resets asynchronously. `submit` and `poll` return promptly on
busy resources. The UI and worker each own a separate D3D11 immediate context.

`submit` copies a borrowed source under the capture mutex and retains no source
pointer. Input slots use keys 0 (UI) and 1 (worker); output slots reverse roles.
`poll` leases an output until `release(token)`. Elga copies it into a repaint
cache before releasing it. Leased pools survive configuration changes.
`destroy` joins the worker only at shutdown.

Worker status belongs to its configuration generation; obsolete setup cannot
override newer settings. A history counter flushes the UI cache and audio ring
on timestamp/cadence resets even if the requested audio delay stays unchanged.
The retry ticket separates explicit retries from resize/capture reconfiguration.
Polling selects the newest completed frame and never goes backward when an older
GPU job completes late. Retired outputs are reclaimed without blocking the UI.

## Hardware acceptance before release

Run CONTRIBUTING.md's checks and GPU tests, then `build-video.ps1` with both SDKs.
Test every toggle combination with all available formats and 720p through 4K.
Exercise true 30→60, 60→120, repeated 30-in-60 input, static scenes, cuts, noisy
input, missing runtimes, signature rejection, and independent SDK failures.

Exercise resize/fullscreen, display changes, rapid toggles, screenshots, stalls,
reconnects, format changes, and minimize/restore. Check D3D11 diagnostics and
VRAM returning after disabling both effects. Measure presentation intervals
and original/generated counts. Use a flash/click source to compare audio timing.
Record GPU, driver, Windows, runtime hashes, input cadence/resolution, processing
time, missed deadlines, and added latency. Claim no 4K throughput until measured.
