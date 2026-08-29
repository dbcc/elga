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
- Selectable native 16:9 resolutions with the highest exposed FPS per size.
- Driver-native color conversion using the 4K X's native YUV sample encoding,
  with no app-level color adjustment or capture-card range changes.
- Low-latency HDMI audio monitoring with selectable Windows output devices.
- Custom client-rendered title bar, borderless fullscreen, always-on-top,
  position pinning, and 16:9 resizing.
- DPI-aware scalable text and crisp vector icon controls.
- Optional presented-frame FPS counter.
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

The optimized executable is written to `build/elga-camera.exe`. For a debug
build, run:

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

- The custom title bar holds the viewer controls, capture mode, and window
  commands while windowed.
- In fullscreen, hover along the top edge for two seconds to reveal the title
  bar. It hides again when the pointer leaves it.
- Click **Fullscreen**, or press `F`/`F11`, to toggle fullscreen.
- Click **Pin position** to lock the current window position.
- Click **Always on top** to keep the viewer above other windows.
- Left-click the audio button to mute or unmute HDMI audio.
- Right-click the audio button to select a Windows output device.
- Click **Color** to use Auto or choose NV12 (8-bit 4:2:0), P010 (10-bit
  4:2:0), YUY2 (8-bit 4:2:2), I420, RGB24, or MJPEG. I420 and MJPEG use NV12;
  RGB24 is expanded to GPU-compatible 32-bit RGB without a YUV conversion.
  This does not apply app-level color, range, contrast, or gamma adjustments.
- Click **Mode** to choose Auto or any native 16:9 resolution exposed for the
  selected pixel format. The highest available FPS for that resolution is used.
- Press `P` to show or hide the displayed-frame FPS value in the title bar.
- Press `Alt+F4` to close the app.

The cursor remains visible in windowed and fullscreen modes. Window resizing is
constrained to 16:9.

## Architecture

Media Foundation selects the requested 16:9 resolution and its highest available
frame rate. Format Auto chooses the best GPU-native mode exposed by the driver
for that resolution, preferring resolution and frame rate and retaining driver
order for otherwise equal modes. The shared video texture is recreated at the
native capture size, so lower-resolution modes do not retain a 4K allocation.
The capture control thread is event-driven and remains asleep unless capture
must stop or recover.
Native NV12, P010, and YUY2 frames remain GPU-to-GPU. I420 is converted and
MJPEG is decoded to NV12; RGB24 is expanded to 32-bit RGB without crossing into
YUV. Transformed frames stay on the GPU when the selected Windows
transform supports DXGI surfaces; a CPU-buffer upload fallback handles
software-only transforms. RGB frames go directly to the shared presentation
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

The 4K X's 4K144 NV12 media type advertises full range even though its sample
values are video range. The viewer does not copy that contradictory flag into
its requested media type; it describes the native YUV sample encoding directly
to the GPU video processor. This avoids the lifted blacks caused by treating
video-range bytes as full-range bytes.

Dear ImGui renders the custom title bar through its D3D11 backend and is
skipped completely while that bar is hidden in fullscreen.

Audio uses Miniaudio's WASAPI backend in low-latency full-duplex mode. Frame-local
Odin allocations use a fixed 64 KiB arena that is reset after every frame.

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

Elgato is a trademark of its respective owner. This project is not affiliated
with or endorsed by Elgato.

## License

No project license has been selected yet. Publishing source code without a
license does not grant permission to copy, modify, or redistribute it. Add an
appropriate root `LICENSE` file before treating Elga Camera as an open-source
project. Licenses and notices for bundled dependencies are documented in
[`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
