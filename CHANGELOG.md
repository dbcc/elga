# Changelog

Notable changes to Elga Camera are documented here. The project follows
[Semantic Versioning](https://semver.org/) once versioned releases begin.

## Unreleased

### Added

- Settings > Input EDID mode reads and changes Merged, Display, or Internal
  directly through the selected 4K X Media Foundation/KS source. Writes require
  protocol validation and matching readback, then recover capture asynchronously.
- Restores normal window size, position, monitor, DPI-scaled placement, and
  always-on-top from `elga-window.ini`.
- F8/Settings screenshot command saves native-resolution PNGs in Pictures/Elga,
  with asynchronous GPU readback, background encoding, and save feedback.
- Settings reconnect command reopens video capture without restarting the app;
  driver shutdown runs in a background worker.
- Capture-health panel reports measured FPS, viewer drops, errors, recovery
  requests, and bounded recent capture/presentation stall history.
- Native Windows viewer for the Elgato 4K X.
- GPU-native NV12, P010, and YUY2 capture paths.
- I420, RGB24, and MJPEG compatibility paths.
- Low-latency HDMI audio monitoring.
- Persistent 0–100% software volume control in a hover flyout on the audio
  button. Changing the volume automatically clears mute.
- Custom title bar and borderless fullscreen controls.
- Online-aware Nintendo Switch 2 wake control using Odin's libcurl bindings.

### Performance

- Capture redraws coalesce behind input so incoming frames do not monopolize
  the window message queue while dragging. Busy presentations return promptly,
  and resize bursts recreate buffers only for the latest requested size.
- Software 2D capture buffers use read-only locks and their actual pitch,
  avoiding unnecessary packed copies and copy-back on unlock.
- Busy capture frames are dropped before COM buffer queries and software-buffer
  merging; redundant audio output selection no longer restarts WASAPI.
- Unused Media Foundation streams are deselected to prevent unread sample queues.
- Direct D3D11 presentation with a double-buffered flip-model swap chain.
- Capture resources are released while minimized.
- Frame-local allocations use a fixed arena.

### Fixed

- The title bar reserves its own space above the video. Window resizing keeps
  the video area at 16:9, and revealing fullscreen controls keeps the full
  image visible below them.
- Window callbacks reclaim temporary settings-path allocations, including
  nested callbacks during resizing and other synchronous window operations.
- Focus changes stay bounded while the overlay is hidden or minimized, and
  returning to the app clears stale held input.
- Busy frame retries no longer depend on another captured frame arriving;
  occluded presentations do not count toward displayed FPS.
- Deferred minimize cleanup protects resources while presentation is active.
- Mouse clicks retain their event coordinates, including quick clicks between
  captured frames. Hover and wake updates run even under continuous painting.
- Valid padded software frames no longer require padding after the final row.
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

### Changed

- Simplified the title bar to fullscreen, audio, and Settings on the left,
  with Switch wake beside the window commands on the right. Capture format,
  resolution, position pinning, and always-on-top are in Settings; capture
  status fits the available width without covering the controls.
