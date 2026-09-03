# Changelog

Notable changes to Elga Camera are documented here. The project follows
[Semantic Versioning](https://semver.org/) once versioned releases begin.

## Unreleased

### Added

- Native Windows viewer for the Elgato 4K X.
- GPU-native NV12, P010, and YUY2 capture paths.
- I420, RGB24, and MJPEG compatibility paths.
- Low-latency HDMI audio monitoring.
- Persistent 0–100% software volume control in a hover flyout on the audio
  button. Changing the volume automatically clears mute.
- Custom title bar and borderless fullscreen controls.
- Online-aware Nintendo Switch 2 wake control using Odin's libcurl bindings.

### Performance

- Direct D3D11 presentation with a double-buffered flip-model swap chain.
- Capture resources are released while minimized.
- Frame-local allocations use a fixed arena.

### Fixed

- Title-bar hover and input remain responsive when capture frames stop.
- Switch wake success and failure feedback returns to idle after two seconds.
- Concurrent app instances use separate temporary volume-settings files.
