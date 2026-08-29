# Manual release checklist

Elga Camera does not use an automated release workflow. Releases are prepared
and published manually.

1. Confirm the working tree contains only the intended release changes.
2. Move relevant entries from `Unreleased` in `CHANGELOG.md` into a versioned
   section using an ISO date.
3. Run the required checks from `CONTRIBUTING.md`.
4. Exercise NV12, P010, YUY2, I420, RGB24, and MJPEG where the hardware exposes
   them. Test minimize/restore and repeated fullscreen transitions.
5. Create a release directory containing:

   - `elga-camera.exe`
   - `README.md`
   - `THIRD_PARTY_NOTICES.md`

6. Generate a checksum:

   ```powershell
   Get-FileHash .\build\elga-camera.exe -Algorithm SHA256
   ```

7. Create an annotated semantic-version tag and push it.
8. Create the GitHub Release from that tag, attach the executable or a ZIP of
   the release directory, include the SHA-256 checksum, and summarize the
   matching changelog section.

Unsigned local builds may trigger Microsoft Defender SmartScreen. Do not claim
that a release is code-signed unless its signature has been verified.
