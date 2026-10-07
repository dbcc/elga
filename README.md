# Elga Camera

Elga Camera is an unofficial, native Windows viewer for the Elgato 4K X capture
card. On its native-format path, video stays on the GPU from capture to
presentation. The base viewer builds as a single standalone executable, with no
installer and no separate DLLs. Optional NVIDIA video enhancements come as a
separate add-on.

> **Project status:** pre-release. The current revision has been tested on
> Windows with an Elgato 4K X, but no packaged release or project license has
> been published yet.

## Features

- **Up to 3840x2160 at 144 FPS**, when the card and host system expose it.
- **Six source formats:** NV12, P010, and YUY2 go straight to the GPU. I420
  and MJPEG are converted to NV12, and RGB24 is expanded to 32-bit RGB, by
  Windows Media Foundation.
- **Faithful color:** the card's native YUV encoding is described directly to
  the D3D11 video processor. The app adds no color, range, gamma, contrast, or
  saturation adjustments, and it never changes the card's color-range setting.
- **Sensible automatic mode selection:** at 4K, Auto prefers the highest rate
  up to 60 FPS, so a 60 Hz HDMI source isn't padded out with duplicate
  120/144 FPS frames.
- **Low-latency HDMI audio monitoring** with software volume, mute, and a
  choice of Windows output device.
- **Input EDID mode control** (Merged, Display, Internal), checked by reading
  the mode back from the card.
- **Optional NVIDIA video enhancements:** RTX Video Super Resolution and 2x
  frame generation, each toggled on its own, with matching audio delay. These
  need a separately built add-on. See
  [video enhancements](docs/VIDEO_ENHANCEMENTS.md).
- **Native-resolution PNG screenshots**, saved in the background.
- **Capture health panel** with measured FPS, drops, errors, and recent stalls.
- **Nintendo Switch 2 wake button** for an ESPHome wake device on the local
  network (optional).
- **Custom title bar**, borderless fullscreen, always-on-top, position pinning,
  16:9 window resizing, and crisp per-monitor DPI scaling.
- **Remembered window placement**, with safe fallback when a monitor has been
  disconnected.

## Requirements

- Windows 10 or 11, x64.
- An Elgato 4K X with its Windows driver installed.
- To build: [Odin](https://odin-lang.org/), Visual Studio C++ Build Tools, and a
  Windows SDK. The Odin revision used for the current build is recorded in
  [`ODIN_VERSION`](ODIN_VERSION). Odin changes quickly, so use that revision
  when reproducing a build.
- Optional, for video enhancements: a supported NVIDIA GPU, plus CMake and the
  NVIDIA SDKs listed in [`native/video/sdk-versions.json`](native/video/sdk-versions.json)
  to build the add-on.

## Building

From PowerShell:

```powershell
.\build.ps1                         # optimized release build
.\build.ps1 -Configuration Debug    # debug build with symbols
```

The script uses `odin.exe` from `PATH`, or `C:\Program Files\Odin\odin.exe` if
it isn't on `PATH`. The build writes `build\elga-camera.exe` and copies
`THIRD_PARTY_NOTICES.md` next to it.

Dear ImGui is vendored under `vendor/`. Miniaudio, libcurl, and stb_image_write
come from Odin's own `vendor:` collection and are statically linked.

`build.ps1` never needs the NVIDIA SDKs. The optional enhancement add-on, a C++
D3D11 worker in `native/video/`, is built separately with `build-video.ps1`.
Run it with no arguments to build and test just the SDK-free transport. To
package the add-on, pass the SDK paths together with `-Package`, then copy the
resulting `enhancements` folder next to `elga-camera.exe`. See
[`docs/VIDEO_ENHANCEMENTS.md`](docs/VIDEO_ENHANCEMENTS.md) for the exact
commands, the add-on's contents, and its validation status.

## Using the app

### Title bar

| Location | Control |
| --- | --- |
| Left | **Fullscreen**, **Audio** (mute / volume / output), **Settings** |
| Middle | Capture status: resolution and displayed FPS, or a connecting or unavailable state |
| Right | **Switch wake**, then minimize, maximize, and close |

Drag the empty parts of the bar to move the window. Window resizing keeps the
video area at 16:9, with the bar's height added above it. In fullscreen, the
bar is hidden. Hold the pointer at the top edge for two seconds to reveal it.
The image shrinks to fit below the bar while it's visible.

### Keyboard

| Key | Action |
| --- | --- |
| `F` or `F11` | Toggle fullscreen |
| `F8` | Save a screenshot |
| `P` | Show or hide the FPS value in the title bar (shown by default) |
| `Alt+F4` | Close |

### Audio

- **Left-click** the audio button to mute or unmute. Mute lasts only for the
  current session.
- **Hover** over it for about 300 ms to open a 0–100% volume slider. Moving the
  slider unmutes audio. The volume is saved.
- **Right-click** it to pick a Windows output device, or the Windows default.

The app finds the card's audio input by name. It looks for a capture endpoint
named "Elgato 4K X", or failing that, any endpoint whose name contains "4K X".
If none is found, video still works but audio is unavailable.

### Settings menu

- **Pin window position**: locks the window's top-left corner for this session.
- **Always on top**: saved with the window layout.
- **Save screenshot** (`F8`): saves the current frame at native resolution,
  without the title bar, as
  `Pictures\Elga\Elga-YYYYMMDD-HHMMSS-mmmZ-NNN.png` (UTC time). Redirected Pictures folders such as
  OneDrive are respected. If Pictures isn't available, screenshots go to a
  `Screenshots` folder next to the executable. Only one screenshot is saved at a
  time.
- **Reconnect capture**: reopens the video device with the current resolution
  and format choices. The driver shutdown runs in the background, so the window
  stays responsive.
- **Capture health**: shows capture and displayed FPS, time since the last
  frame, frames dropped by the viewer, conversion and capture errors, recovery
  requests, and the five most recent stalls of 500 ms or longer. Counts cover
  the current session. Frame loss inside the driver and HDMI signal status
  aren't measured. While an enhancement is on, the panel also shows the
  enhanced output rate, processing time, added delay, and missed deadlines.
- **Video enhancements**: all three options start off, and the choices are
  saved.
  - **RTX Video Super Resolution** upscales the video to the window size, up to
    4K.
  - **Frame generation (2x)** interpolates frames. It adds about 33 ms of
    latency at 60 FPS, or 67 ms at 30 FPS, and delays the audio to match. Your
    display must support twice the source frame rate.
  - **Game frame rate: 30 FPS** is for 30 FPS games sent in a 60 FPS signal,
    such as on the Switch 2. It only affects frame generation.

  Each option shows **Unavailable** when the add-on, the GPU, or the driver
  doesn't support it.
- **Input EDID mode**: reads and changes the card's EDID policy.
  - **Merged (recommended)**: the card combines the capture and display
    capabilities.
  - **Display**: follows the attached TV or monitor.
  - **Internal**: uses the EDID already stored on the card.

  A change briefly interrupts the HDMI signal while the card renegotiates. It
  is reported as successful only after a separate readback confirms it. The app
  doesn't save or reapply a preferred mode. If the mode shows as unknown, use
  **Refresh mode** instead of picking the same mode again.
- **Resolution**: Auto, or any native 16:9 resolution the selected format
  offers. Auto picks the largest resolution. At 4K it prefers the highest rate
  up to 60 FPS, or the lowest advertised rate if none is at or below 60. Picking
  a resolution explicitly, including 3840x2160, uses that resolution's highest
  rate.
- **Color format**: Auto (the best GPU-native format) or any format the card
  offers: NV12, P010, YUY2, I420, RGB24, or MJPEG.
- **Show frame rate** (`P`).

### Switch 2 wake (optional)

The power button on the right of the title bar talks to an
[ESPHome](https://esphome.io/) device on the local network. That device must:

- be reachable at `switch2-waker.local`,
- have the ESPHome `web_server` component enabled, and
- expose a button entity named `Wake Switch 2`.

The app checks the button every 5 seconds. The command is enabled only while
the button is reachable. Pressing it sends
`POST /button/Wake%20Switch%202/press` in the background, so video never
stalls. Without such a device, the button stays disabled and the rest of the
app is unaffected.

### Saved settings

Both files are written next to the executable, so the app stays portable.

| File | Contents |
| --- | --- |
| `elga-camera.ini` | Audio volume |
| `elga-window.ini` | Normal window size, position, monitor, and always-on-top |
| `elga-video.ini` | Video enhancement choices |

Closing the app while it's maximized, minimized, or fullscreen still saves the
normal window placement. If the saved monitor is no longer connected, the
window opens on an available display.

## How it works

**Capture.** Media Foundation's source reader opens the 4K X in the selected
16:9 mode, and unused streams are deselected so unread samples don't pile up.
A capture control thread stays asleep unless capture must stop, recover, or
service an EDID request. Recovery waits for Media Foundation's flush callback.
On shutdown, outstanding callbacks are detached before capture resources are
released.

**Video path.** NV12, P010, and YUY2 frames go from GPU to GPU. I420 and MJPEG
are converted to NV12, and RGB24 to 32-bit RGB, by a Windows transform. Results
stay on the GPU when the transform supports DXGI surfaces. Otherwise the app
falls back to a CPU upload that uses a read-only lock and the buffer's real row
pitch. The D3D11 video processor converts YUV frames to RGB using an explicit
D3D11.1 color space. A pass-through shader then presents the result through a
double-buffered flip-model swap chain. The native GPU path has no CPU frame
download, CPU color conversion, or CPU-to-GPU upload.

**Color range.** In its 4K144 NV12 mode, the 4K X labels its output as full
range even though the sample values are video range. The viewer ignores that
label and tells the video processor the real encoding, which avoids washed-out
blacks.

**Responsiveness.** If the presentation texture is busy, the incoming capture
frame is dropped before any buffer work is done. Repaints reuse the last
complete frame, so the controls keep working when HDMI stalls. Paints are
combined so that queued input is handled first, and a timer retries busy
presentations even when no new frame arrives. During a resize, only the latest
size is applied. While the window is minimized, capture-sized textures are
released and the swap chain shrinks to 1x1.

**UI.** Dear ImGui draws the title bar through its D3D11 backend. It is skipped
entirely while the bar is hidden in fullscreen, except to show screenshot
messages. Screenshots copy the frame back from the GPU only when you ask for
one, and they don't block the window: a worker thread encodes the PNG.

**Audio.** Miniaudio runs WASAPI in low-latency full-duplex mode, capturing the
card's audio input and playing it on the selected output. Volume is applied as
linear gain in the real-time callback. When frame generation adds video delay,
a preallocated ring buffer in the same callback delays audio by the same
amount, up to 250 ms.

**Video enhancements.** The optional add-on runs on its own D3D11 worker with
bounded shared-texture queues, and frames stay on the GPU. Capture callbacks
never wait for it. If the add-on is missing or fails, the viewer falls back to
the normal path. See [`docs/VIDEO_ENHANCEMENTS.md`](docs/VIDEO_ENHANCEMENTS.md).

**Memory.** Per-frame allocations come from a fixed 64 KiB arena that is reset
after every frame. Window callbacks free their temporary allocations when they
return.

**EDID.** EDID requests use the same capture worker and the same live Media
Foundation source as video. Before enabling writes, the worker finds the
matching KS extension node, checks property support, confirms protocol
version 4, and reads the current mode. Writes are never retried automatically.
After any write that may have reached the card, capture reconnects and devices
are enumerated again. See [`docs/EDID_PROTOCOL.md`](docs/EDID_PROTOCOL.md) for
the transport details and test fixtures.

## Hardware verification

On the development system, the 4K X negotiated 3840x2160 NV12 at 144.001 FPS.
The viewer captured and presented about 144 frames per second and completed
twelve consecutive fullscreen transitions without crashing. NV12, P010, and
YUY2 were also tested at native 720p, 1080p, 1440p, and 2160p.

On 2026-09-11, the EDID transport was checked on a connected 4K X (PID `009B`).
Protocol identification, changes to Merged, Display, and Internal, separate
readback, capture recovery, minimize and restore, and refresh all passed, and
the original Merged mode was restored afterwards. Physical unplug and replug
testing is still pending.

**EDID troubleshooting:** close other capture apps, connect the 4K X directly to
the PC, make sure a display is attached to the card's HDMI output, reopen the
viewer, and choose **Refresh mode**. EDID writes stay disabled whenever the
protocol or the current mode can't be verified.

## Repository layout

```text
src/             Application source, tests, and local Windows API bindings
native/video/    Optional C++ NVIDIA video enhancement backend (CMake)
vendor/          Vendored Dear ImGui Odin bindings and static library
docs/            EDID protocol, video enhancements, release checklist, reviews
.github/         Issue and pull request templates
build.ps1        Release and debug build script for the viewer
build-video.ps1  Build, test, and package script for the enhancement add-on
```

## Contributing and releases

[`CONTRIBUTING.md`](CONTRIBUTING.md) lists the setup, the required local checks
(`odin check`, `odin test`, the stress-define build, the optional GPU tests, and
a release build), and what to report from hardware testing. There's no hosted
CI, so these checks are run locally. Please use the GitHub issue templates so
the capture mode and system details are included.

Releases are prepared by hand using [`docs/RELEASING.md`](docs/RELEASING.md).
User-visible changes are tracked in [`CHANGELOG.md`](CHANGELOG.md).

## License

No project license has been chosen yet. Publishing the source without a license
doesn't grant anyone permission to copy, modify, or redistribute it. Add a root
`LICENSE` file before treating Elga Camera as open source. Licenses for bundled
dependencies are listed in [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).

Elgato is a trademark of its respective owner. This project is not affiliated
with or endorsed by Elgato.
