# 4K X Input EDID protocol contract

This module is an interoperability implementation for the Elgato 4K X. It has
no runtime dependency on Elgato or Realtek software. The contract below was
derived from the locally installed 4K Capture Utility transport and is kept
isolated from the Windows COM bindings in `src/edid.odin` and
`src/edid_windows.odin`.

## Source and extension binding

The controller is opened from the exact `IMFMediaSource` activated for capture.
The selected source must identify as a 4K X. EDID access is enabled only when
its Media Foundation symbolic link contains Elgato VID `0FD9` and a known
EDID-capable 4K X PID (`009B` or `009C`); both `Elgato 4K X` and
`Game Capture 4K X` friendly-name variants are accepted. `IKsTopologyInfo`
enumerates every node. A node is accepted only when an
`IKsControl` instance reports GET and SET basic support for properties 1 and 2
of extension set `{961073C7-49F7-44F2-AB42-E940405940C2}`. No fixed topology
node number or preferred node order is assumed. Each supported node is checked
for protocol identification and mode readback. If none verifies, the first
supported node is retained only for explicit read retries; mode writes remain
disabled.

Each property transfer queries `IKsTopologyInfo`, creates a fresh `IKsControl`
node instance, performs one `KsProperty` call, and releases both interfaces.
This mirrors the vendor transport and avoids relying on driver state attached
to a reusable node instance.

## Transfer framing

- The inner request is a four-byte little-endian command followed by its
  optional payload. It must be wrapped in the RTICE service framing below;
  sending the inner bytes directly makes the connected card time out.
- For the short frames used here: service byte, one-byte body length, two
  zero bytes, inner request, checksum. The body length includes the two zero
  bytes and inner request. The checksum makes the sum of all bytes zero modulo
  256. Service is `A0` for protocol identification and `A1` for mode GET/SET.
- Replies use the same service/length/checksum framing. The decoder verifies
  all three, rejects a complemented service (device error), and removes the
  two prefix bytes before returning the command result. Extended-length
  frames are unsupported and rejected; EDID commands do not need them.
- SET property 2 receives the request length as a little-endian `u16`.
- SET property 1 receives the request bytes.
- GET property 2 returns the response length as a `u16`. Zero means the
  response is not ready and is polled at 10 ms intervals for at most 100 polls.
  The vendor transport ignores this call's `BytesReturned`; zero is therefore
  tolerated for compatibility when the two-byte length field is valid,
  while partial and oversized nonzero counts are rejected.
- GET property 1 is offered a 512-byte buffer, matching the inspected vendor
  transport. The announced length must match the command's expected response;
  the driver byte count may be that logical length or the fixed 512-byte XU
  transfer, but it may never be shorter than the response or exceed the buffer.
- Cancellation is checked between synchronous KS calls. The one-second polling
  bound does not and cannot cancel a driver call already executing.

Identification and mode reads return four-byte little-endian values on the
connected 4K X, not one-byte responses. Command `0x67` identifies the
protocol and must return version `4`. It is executed before a mode read or a
write. Command `0x4E` reads the mode. Command `0x4D` writes a four-byte
little-endian device value. Device values are Internal `0`, Display `1`, and
Merged `4`.

## Wire evidence (2026-09-11)

The initialized vendor library resolves AT command dispatch through virtual
method RVA `0xC9E70`, protocol framing through `0x43CD0`, response parsing
through `0x49CC0`, and additive checksum generation through `0x20ED0` in
the installed `RTK_IO_x64.dll` (2024-04-08 build). The previously inspected
inner-command builder alone omitted this protocol layer.

Direct Windows KS reads on the connected PID `009B` device, node 3:

| Operation | Request (property 1 SET) | Reply (property 1 GET) |
| --- | --- | --- |
| Protocol version | `A0 06 00 00 67 00 00 00 F3` | `A0 06 00 00 04 00 00 00 56` |
| Current mode (Merged) | `A1 06 00 00 4E 00 00 00 0B` | `A1 06 00 00 04 00 00 00 55` |

Both requests announce length 9 through property 2. Data GET offers 512 bytes
and the driver returns 9 meaningful bytes. The original raw request reproduced
the timeout on the same source; the framed request returns immediately.
SET framing derived from the same dispatch is `A1 0A 00 00 4D 00 00 00`
followed by a four-byte mode and checksum. Hardware SET acceptance followed
verified read-only identification and mode readback. Merged → Display → Internal
→ Merged all returned `Applied` with matching separate GET responses. Each new
diagnostic process also read the previously selected mode successfully. SET
replies contained the four-byte mode:
`A1 06 00 00 01 00 00 00 58` for Display,
`A1 06 00 00 00 00 00 00 59` for Internal, and
`A1 06 00 00 04 00 00 00 55` for Merged. Original Merged mode was restored.

Read-only identification and mode commands follow the vendor transport's
three-attempt behavior. Mode writes remain single-shot and are never retried.

SET is enabled only after `0x67` and `0x4E` both succeed with recognized
values. A requested value is confirmed only by a separate post-write protocol
check and `0x4E` readback. A different recognized value is a mismatch and is
reported as the actual mode. A failure after the data write is uncertain: the
selection is cleared, capture is re-opened, and the write is never repeated.

## Test fixtures

`src/edid_test.odin` models the length/data properties and records every framed
packet. It covers all device-value mappings, exact SET framing, protocol-version
rejection, unknown modes, polling exhaustion, oversized and truncated
responses, unsupported property capabilities, cancellation, pre-write failure,
uncertain write failure, readback mismatch, single-operation mailbox behavior,
stale generation rejection, stale window messages arriving before a newer
result, retry after an error, and minimize during an active operation.

The application hardware smoke test also passed all three mode changes through
the real UI mailbox and capture worker, reopening 3840x2160 NV12 capture at
144.001 FPS after each change. It received new video samples with zero source
errors, completed asynchronous minimize/restore and refresh, and shut down
cleanly. Its UI timer drove every stage; rendering resumed after window restore.
Physical unplug/replug and shutdown specifically during an active transaction
remain pending hardware acceptance cases.

The one-off probe and automatic mode-cycling hooks used for this investigation
have been removed from application code. Captured wire fixtures remain in the
test suite. To repeat hardware acceptance with the normal app:

1. Record the current mode under **Settings > Input EDID mode**.
2. Select each of Display, Internal, and Merged, allowing capture to recover
   after each signal interruption. Use **Refresh mode** to confirm readback.
3. Restart the app and confirm that it reads the last selected hardware mode.
4. Minimize and restore the window, then refresh the mode again.
5. Restore the original mode. Exercise unplug/replug and shutdown during a
   transaction separately; do not automatically retry an uncertain write.

Device access may require running the app outside the development sandbox.
