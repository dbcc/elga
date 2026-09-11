# Elga Camera

Elga Camera is an unofficial, native Windows viewer for the Elgato 4K X. Its
native-format path keeps video on the GPU from capture through presentation,
and it builds as one standalone executable.

> **Project status:** pre-release. The current revision is hardware-tested on
> Windows with an Elgato 4K X, but packaged releases and a project license have
> not yet been published.

## Features

- Up to 3840x2160 at 144 FPS when exposed by the capture card and host system.
- Automatic or manual NV12, P010, YUY2, I420, RGB24, and MJPEG source modes.
- GPU-native presentation for NV12/P010/YUY2, with Windows Media Foundation
  conversion to NV12 or 32-bit RGB for compatibility formats.
- Selectable native 16:9 resolutions; 4K automatic selection prefers 60 FPS
  so a 60 Hz HDMI source is not expanded into duplicate 120/144 FPS samples.
- Driver-native color conversion using the 4K X's native YUV sample encoding,
  with no app-level color adjustment or capture-card range changes.
- Low-latency HDMI audio monitoring with software volume, mute, and selectable
  Windows output devices.
- One-click Nintendo Switch 2 wake control through a networked ESPHome wake
  beacon available as `switch2-waker.local`.
- Custom client-rendered title bar, borderless fullscreen, always-on-top,
  position pinning, and 16:9 resizing.
- DPI-aware scalable text and crisp vector icon controls.
- Optional presented-frame FPS counter.
- Remembered window layout and monitor, with safe restoration after a display
  is disconnected; always-on-top is restored too.
- Native-resolution PNG screenshots, manual capture reconnect, and detailed
  capture health in Settings.
- Hardware-authoritative Input EDID mode control for Merged, Display, and the
  EDID already stored internally on the card.
- No runtime installer or separately distributed DLLs.

## Requirements

- Windows 10 or 11, x64.
- Elgato 4K X and its Windows driver.
- For building: [Odin](https://odin-lang.org/), Visual Studio C++ Build Tools,
  and a Windows SDK.

The exact Odin revision used for the current build is recorded in
[`ODIN_VERSION`](ODIN_VERSION). Odin is evolving quickly, so use that revision
when reproducing a release or diagnosing compiler-specific behavior.

## Build

From PowerShell:

```powershell
.\build.ps1
```

The optimized executable and required third-party notices are written to
`build/`. For a debug build, run:

```powershell
.\build.ps1 -Configuration Debug
```

The script finds `odin.exe` on `PATH` and falls back to
`C:\Program Files\Odin\odin.exe`.

To run the same local checks expected for contributions:

```powershell
odin check src -vet -strict-style
odin check src -vet -define:ELGA_FULLSCREEN_STRESS=true -define:ELGA_FORMAT_STRESS=true
.\build.ps1 -Configuration Release
```

There is intentionally no hosted CI workflow; validation is performed locally
and hardware behavior is recorded with each release.

## Controls

- The minimal title bar keeps fullscreen, audio, and Settings on the left,
  with Switch wake beside the standard window commands on the right. Capture
  status uses the space available between them.
- In fullscreen, hover along the top edge for two seconds to reveal the title
  bar. The full image fits below the visible bar; it fills the screen again
  when the bar hides after the pointer leaves it.
- Click **Fullscreen**, or press `F`/`F11`, to toggle fullscreen.
- Open **Settings** for capture options, **Pin window position**, and **Always on top**.
- Left-click the audio button to mute or unmute HDMI audio.
- Hover over the audio button for about 300 ms to open the 0–100% software
  volume slider. The selected volume is saved in `elga-camera.ini` beside the
  executable. Changing the slider automatically unmutes audio; mute itself is
  session-only and is not saved.
- Right-click the audio button to select a Windows output device.
- Press **F8**, or choose **Settings > Save screenshot**, to save the current
  native-resolution frame as a PNG in **Pictures/Elga**, without the toolbar.
  One screenshot is saved at a time; encoding runs in the background. If the
  Pictures location is unavailable, the app uses `Screenshots` beside the executable.
- Choose **Settings > Reconnect capture** to reopen the video capture device
  with the current resolution and format preferences. Driver shutdown runs in
  the background so window input remains responsive.
- Open **Settings > Input EDID mode** to read or change the 4K X's current EDID
  policy. **Merged** lets the card reconcile capture and display capabilities,
  **Display** follows the attached display, and **Internal** uses the EDID
  already stored on the card. The app does not save or reapply a preferred
  mode. A change briefly interrupts the HDMI/capture signal while the card and
  capture pipeline renegotiate; success is reported only after an independent
  hardware readback. If the mode is unknown, use **Refresh mode** rather than
  selecting the same mode again.
- Open **Settings > Capture health** for measured capture and displayed FPS,
  viewer drops, conversion/capture errors, recovery requests, and recent stalls
  of at least 500 ms. Counts cover the current app session. Driver-side frame
  loss and HDMI signal status are not inferred from these counters.
- The normal window size, position, monitor, and always-on-top setting are
  saved in `elga-window.ini` beside the executable. Maximized, minimized, and
  fullscreen closes preserve normal placement; missing monitors fall back to
  an available display. These settings are separate from audio volume.
- Click the power icon on the right of the title bar to ask `switch2-waker.local` to wake the
  Nintendo Switch 2. The request runs in the background and does not stall video. The
  command is enabled only while the ESPHome wake entity is reachable.
- Open **Settings > Color format** to use Auto or choose NV12 (8-bit 4:2:0), P010 (10-bit
  4:2:0), YUY2 (8-bit 4:2:2), I420, RGB24, or MJPEG. I420 and MJPEG use NV12;
  RGB24 is expanded to GPU-compatible 32-bit RGB without a YUV conversion.
  This does not apply app-level color, range, contrast, or gamma adjustments.
- Open **Settings > Resolution** to choose Auto or any native 16:9 resolution exposed for the
  selected pixel format. Auto prefers the highest available 4K rate up to 60
  FPS; selecting 3840x2160 explicitly uses its highest available rate. Lower
  resolutions continue to use their highest available rate.
- Press `P` to show or hide the displayed-frame FPS value in the title bar.
- Press `Alt+F4` to close the app.

The cursor remains visible in windowed and fullscreen modes. The title bar has
its own space above the image. Window resizing keeps the video area at 16:9,
with the bar's DPI-scaled height added above it.

## Architecture

Media Foundation selects the requested 16:9 resolution. Automatic resolution
selection prefers the highest native 4K rate up to 60 FPS because the 4K X can
advertise 120/144 FPS USB modes even for a 60 Hz HDMI signal; requesting those
modes merely duplicates frames. Explicit resolutions and lower resolutions
retain the highest-rate policy. Format Auto chooses the best GPU-native mode
under the same policy and retains driver order for otherwise equal modes. The
shared video texture is recreated at the
native capture size, so lower-resolution modes do not retain a 4K allocation.
The capture control thread is event-driven and remains asleep unless capture
must stop or recover.
Input EDID requests use the same capture worker and the live Media Foundation
source selected for video. The worker discovers the matching KS extension node,
checks its property support, validates protocol version 4, and reads the card
before SET is enabled. It pauses sample reissuance and drains callbacks around
each transaction. A write is never automatically retried: an uncertain result
clears the selection, and any write that may have reached the card is followed
by the existing asynchronous capture reconnect and fresh device enumeration.
See [`docs/EDID_PROTOCOL.md`](docs/EDID_PROTOCOL.md) for the bounded transport
contract and fixtures.
Startup resolves Auto against the enumerated device modes. Recovery waits for
Media Foundation's flush callback, and shutdown detaches outstanding callbacks
before releasing capture resources. Unused source streams are deselected so
unread samples do not accumulate.
Native NV12, P010, and YUY2 frames remain GPU-to-GPU. I420 is converted and
MJPEG is decoded to NV12; RGB24 is expanded to 32-bit RGB without crossing into
YUV. Transformed frames stay on the GPU when the selected Windows
transform supports DXGI surfaces; a CPU-buffer upload fallback handles
software-only transforms. Software 2D surfaces use a read-only lock and their
actual row pitch, avoiding the packed copies made by a generic buffer lock.
RGB frames go directly to the shared presentation
texture. For YUV frames, the Windows D3D11 video processor performs the
mandatory RGB display conversion using the video-range samples and an explicit
D3D11.1 DXGI matrix color space. A plain
pass-through shader then presents that output through a D3D11 double-buffered
flip-model swap chain. When minimized, the viewer releases its
capture-sized textures and shrinks the swap chain to 1x1, then recreates only
the active native mode on restore. The app has no custom color matrix, range expansion,
gamma, contrast, or saturation adjustment and does not write the 4K X hardware
color-range policy. The GPU-native hot path has no CPU frame download,
CPU-side RGBA conversion, or CPU-to-GPU texture upload.
When the output viewport covers the client area, the renderer also skips the
otherwise redundant full-surface clear before drawing the video frame.
Busy capture frames are dropped before buffer preparation. Repaints can reuse
the last completed shared frame, keeping controls responsive when HDMI stalls.
Capture invalidates the window for a coalesced paint after pending input,
including during dragging. Presentation does not wait on a full display queue;
busy frames retry through a timer even if no new capture arrives. Resize bursts
apply only the latest client size at the next paint, and UI timers also tick
from paints so continuous capture does not delay hover controls.

The 4K X's 4K144 NV12 media type advertises full range even though its sample
values are video range. The viewer does not copy that contradictory flag into
its requested media type; it describes the native YUV sample encoding directly
to the GPU video processor. This avoids the lifted blacks caused by treating
video-range bytes as full-range bytes.

Dear ImGui renders the custom title bar through its D3D11 backend and is
skipped while that bar is hidden in fullscreen, except for brief screenshot
notifications. Screenshot readback is requested only on demand, polls the GPU
without waiting, and preserves shared-frame ownership. A worker converts the
mapped BGRA frame to an opaque PNG and writes it without blocking the window.

Audio uses Miniaudio's WASAPI backend in low-latency full-duplex mode. Volume is
applied as linear software attenuation in the real-time callback. Frame-local Odin
allocations use a fixed 64 KiB arena that is reset after every frame.
Window callbacks separately reclaim their temporary allocations on return,
preserving any outer callback's memory during reentry. Focus changes are
coalesced while the overlay is hidden or minimized so input events do not
accumulate while rendering is paused.

## Source layout

```text
src/        Application source and local Windows API bindings
vendor/     Vendored Dear ImGui Odin bindings and static library
docs/       Maintainer and release documentation
.github/    Issue and pull-request templates
build.ps1   Release/debug build entry point
```

## Contributing and releases

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for setup, verification, and hardware
reporting expectations. Bugs and feature requests should use the GitHub issue
templates so capture mode and system details are not omitted.

Releases are prepared manually using [`docs/RELEASING.md`](docs/RELEASING.md).
User-visible changes are tracked in [`CHANGELOG.md`](CHANGELOG.md).

## Verified hardware path

On the development system, the Elgato 4K X negotiated 3840x2160 NV12 at
144.001 FPS. The viewer sustained approximately 144 captured and presented
frames per second and completed twelve consecutive fullscreen transitions
without a crash. NV12, P010, and YUY2 paths were also exercised across native
720p, 1080p, 1440p, and 2160p modes.

On 2026-09-11, the standalone EDID transport was verified on a connected 4K X
(PID `009B`): protocol identification, Merged/Display/Internal changes, separate
mode readback, capture recovery, minimize/restore, and refresh all passed.
The original Merged mode was restored. Tests include captured request/reply
fixtures, framing/checksum validation, and mocked failure handling. Physical
unplug/replug acceptance remains pending. The app keeps SET unavailable whenever
protocol identification or current-mode readback cannot be verified. For EDID
troubleshooting, close other capture applications, reconnect the 4K X directly
to the PC, confirm the display is attached to the card's HDMI output, reopen
the viewer, and choose **Refresh mode**. A synchronous driver call itself cannot
be cancelled; shutdown and minimize cancellation is observed between calls.

Elgato is a trademark of its respective owner. This project is not affiliated
with or endorsed by Elgato.

## License

No project license has been selected yet. Publishing source code without a
license does not grant permission to copy, modify, or redistribute it. Add an
appropriate root `LICENSE` file before treating Elga Camera as an open-source
project. Licenses and notices for bundled dependencies are documented in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
