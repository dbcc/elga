# Memory review — 2026-09-07

Reviewed application allocation lifetimes, COM references, GPU resources,
worker threads, native handles, settings, screenshots, audio, wake requests,
and hidden UI input. Existing uncommitted feature work was preserved.

## Confirmed growth and fixes

| Path | Evidence | Fix |
| --- | --- | --- |
| Window settings outside rendering | A settings-save attempt retained 159 bytes in the default temporary arena. Rendering resets a separate frame arena, so it never reclaims these path strings. | A scoped temporary-allocator guard in the window callback rewinds each invocation, including early returns, and preserves an outer invocation during synchronous reentry. Main has the same guard for startup/shutdown work. |
| Focus changes while UI rendering is paused | 10,000 focus-loss/gain cycles produced 20,000 queued ImGui events with capacity 26,151 when no frame consumed them. | Store pending focus in fixed boolean fields and apply it when rendering/input resumes. Any intervening focus loss clears stale held input; the first click after activation is preserved. |
| GPU test initialization failures | Software-buffer QueryInterface/Lock failures could return before registering the buffer's release. | Register cleanup before any initialization branch can fail. This is a test-harness fix. |

Odin's default temporary allocator requires explicit reclamation; see the
[official allocator documentation](https://odin-lang.org/docs/overview/#allocators).
The installed runtime's scope guard uses an arena checkpoint, which is safer
for nested callbacks than clearing the entire arena.

## Ownership review

No additional leak was substantiated in the reviewed capture, rendering,
screenshot, audio, or wake paths. The relevant existing cleanup includes:

- Releasing Media Foundation enumeration results, strings, samples, buffers,
  textures and reader interfaces; unlocking software buffers on failure;
  detaching callbacks before source shutdown; joining capture workers.
- Unbinding GPU context references, releasing shared textures and handles,
  flushing resource disposal, and releasing partial initialization results.
- Limiting screenshots to one job, joining the encoder before unmapping its
  input, and releasing its path, pixel buffer, file handle, and readback state.
- Pairing Miniaudio device/context initialization with teardown, and libcurl
  requests with handle cleanup; joining and destroying wake workers.
- Keeping capture mode lists and health history in fixed-capacity storage.

## Verification

- Strict compiler/vet/style check passed, as did the fullscreen/format stress
  compile check.
- All 41 standard tests and all 43 GPU-enabled tests passed with 32 test threads.
  Odin's allocation tracker reported no issues.
- The callback regression repeats 64 messages and verifies unchanged arena
  usage and intact outer allocations. A copied baseline with only the callback
  guard removed fails after its first message (415 bytes used versus 256).
- The ImGui regression verifies 10,000 focus cycles with at most two queued
  events, held-button cleanup, final focus state, and the first new click.
- New capture regressions run 32 rejected-frame cycles with real Media
  Foundation software/2D buffers, verify lock release, and check final sample
  and buffer COM reference counts reach zero.
- Release compilation and packaging succeeded in `build/memory-review/`.
  The normal build script first failed copying the existing notices file; a
  retry could not overwrite `build/elga-camera.exe` because it was running.
  The separate build uses the same release compiler flags and includes notices.

The installed compiler is `dev-2026-09-nightly:a2fb372`, newer than the revision
in `ODIN_VERSION`. Small existing syntax/API incompatibilities in the current
feature work were corrected to enable validation. ImGui tests share a mutex
because the vendored library's current context is global.

These results cover reproducible application leaks and tested ownership paths.
They do not prove absence of retention inside Windows capture transforms,
Miniaudio, ImGui, libcurl, or GPU drivers during prolonged hardware use. An
extended capture run with repeated reconnect, format, minimize/restore, and
screenshot operations remains necessary to assess those native allocations.
