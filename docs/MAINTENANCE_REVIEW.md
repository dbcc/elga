# Maintenance review — 2026-09-04

Reviewed the application source, local Windows bindings, existing tests, and
build script. Vendored dependencies were left unchanged.

## Changes

| Area | Finding and change |
| --- | --- |
| GPU synchronization | Positive timeout/abandoned HRESULTs were mistaken for successful mutex acquisitions. Only S_OK permits texture access. Busy frames now skip buffer preparation, and unsuccessful uploads return the capture key. |
| Presentation | Repainting without a new frame could access an unowned texture or present black. Repaints can acquire the last completed frame, contention skips presentation, and FPS counts the frame actually drawn. |
| Callback lifetime | The COM callback lived on the capture thread's stack. It now has a reference-counted heap lifetime and detaches from the renderer before teardown. |
| Recovery | A fixed sleep substituted for asynchronous flush completion. Recovery now waits for OnFlush and can be interrupted by shutdown. Stale failures cannot restart capture while minimized. |
| Capture context | Enabled Direct3D multithread protection for the context shared with Media Foundation. |
| Memory | Deselect unread Media Foundation streams, clear mode publication before every restart, and preserve unlock/release paths on malformed or failed buffers. |
| Frame bounds | Validate software stride/length without arithmetic overflow. GPU copies validate dimensions, format, and subresource, and crop alignment padding. |
| Auto mode | Resolve the provisional 4K NV12 startup allocation against enumerated modes, with a guard against repeated Auto retries after rollback. |
| Window controls | Top/bottom resizing now follows height. Keyboard auto-repeat no longer repeatedly toggles fullscreen or FPS visibility. |
| Audio | Selecting the active output avoids a device restart; invalid selections leave it running. Short input buffers leave a silent output tail. |
| Simplification | Consolidated upload ownership/cleanup and wake HTTP configuration, removed an unused format mapping, and requested only the D3D11.1 interface needed for shared handles. |

## Verification

- Strict compiler/vet checks, including both existing stress definitions.
- Unit regressions cover mutex results, early frame drops, callback detachment
  and COM references, flush completion/cancellation, malformed buffers, exact
  mode ranking, minimized failures, window resizing, audio, and settings.
- The optional GPU test sends synthetic frames through both IMFMediaBuffer and
  padded DXGI surfaces for NV12, P010, YUY2, I420, RGB24, and MJPEG presentation
  paths. It checks shared ownership, conversion, shader output, repeated
  repaints, and pixel readback. I420/MJPEG inputs simulate the already-converted
  NV12 output; RGB24 inputs simulate the already-expanded BGRA output.
- Release and debug builds; a fullscreen stress run completed 12 transitions
  and exited with code 0.

The compiler installed for this review is
`dev-2026-09-nightly:a2fb372`, newer than the revision in `ODIN_VERSION`.
Odin's test allocator tracking reported no issues. That tracking does not cover
all allocations owned by Windows, COM, GPU drivers, or bundled C libraries.

Actual capture and audio initialization failed in this execution environment.
Device negotiation, Windows decoding transforms, sustained capture FPS,
long-running GPU/driver memory use, and live audio still need hardware testing.
The changes reduce specific unnecessary work; no end-to-end performance gain is
claimed without a comparable hardware benchmark.

## API references

- [AcquireSync return values and ownership](https://learn.microsoft.com/en-us/windows/win32/api/dxgi/nf-dxgi-idxgikeyedmutex-acquiresync)
- [Asynchronous source-reader flush](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-imfsourcereader-flush)
- [Unused streams can accumulate unread samples](https://learn.microsoft.com/en-us/windows/win32/api/mfreadwrite/nf-mfreadwrite-imfsourcereader-setstreamselection)
- [Direct3D 11 Media Foundation multithread protection](https://learn.microsoft.com/en-us/windows/win32/medfound/supporting-direct3d-11-video-decoding-in-media-foundation)
