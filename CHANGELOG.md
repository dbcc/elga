# Changelog

Notable changes to Elga Camera are documented here. The project follows
[Semantic Versioning](https://semver.org/) once versioned releases begin.

## Unreleased

### Added

- Native Windows viewer for the Elgato 4K X.
- GPU-native NV12, P010, and YUY2 capture paths.
- I420, RGB24, and MJPEG compatibility paths.
- Low-latency HDMI audio monitoring.
- Custom title bar and borderless fullscreen controls.
- Background Nintendo Switch 2 wake control using Odin's libcurl bindings.

### Performance

- Direct D3D11 presentation with a double-buffered flip-model swap chain.
- Capture resources are released while minimized.
- Frame-local allocations use a fixed arena.
