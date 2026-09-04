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

- Busy capture frames are dropped before COM buffer queries and software-buffer
  merging; redundant audio output selection no longer restarts WASAPI.
- Unused Media Foundation streams are deselected to prevent unread sample queues.
- Direct D3D11 presentation with a double-buffered flip-model swap chain.
- Capture resources are released while minimized.
- Frame-local allocations use a fixed arena.

### Fixed

- GPU mutex timeouts no longer count as successful acquisitions; failed uploads
  release ownership for retry, and UI repaints reuse the last completed frame.
- Capture callbacks have reference-counted lifetimes and detach before shutdown;
  recovery waits for asynchronous flush completion and can be cancelled.
- Enable thread protection for the capture device shared with Media Foundation.
- Auto startup resolves the actual device modes instead of assuming 4K NV12.
- Padded GPU surfaces copy only the image area; software uploads reject invalid
  sizes and strides and always unlock successfully locked buffers.
- Top/bottom window resizing follows height, and held shortcuts toggle only once.
- Audio callbacks clear any output tail when input has fewer samples.
- Title-bar hover and input remain responsive when capture frames stop.
- Switch wake success and failure feedback returns to idle after two seconds.
- Concurrent app instances use separate temporary volume-settings files.
