# Contributing

Thanks for helping improve Elga Camera. Changes should keep the native capture
path small, predictable, and free of CPU frame copies whenever Windows exposes
a GPU surface.

## Development setup

You need Windows 10 or 11 x64, Visual Studio C++ Build Tools with a Windows SDK,
and Odin. The compiler revision used for the current build is recorded in
[`ODIN_VERSION`](ODIN_VERSION).

Clone the repository with normal Git settings; the Dear ImGui Odin bindings and
Windows static library are vendored, so there are no submodules to initialize.

Build from PowerShell:

```powershell
.\build.ps1 -Configuration Debug
```

## Required local checks

Run these before opening a pull request:

```powershell
odin check src -vet -strict-style
odin test src -vet -strict-style -out:build/elga-tests.exe
odin check src -vet -define:ELGA_FULLSCREEN_STRESS=true -define:ELGA_FORMAT_STRESS=true
.\build.ps1 -Configuration Release
```

The stress defines compile the fullscreen and capture-format transition paths.
On a machine with a D3D11 video-capable GPU, also run the synthetic pixel tests:

```powershell
odin test src -vet -strict-style -define:ELGA_GPU_TESTS=true -out:build/elga-gpu-tests.exe
```

These check all six presentation formats through software buffers and padded
DXGI surfaces, shared-texture ownership, and GPU readback. They do not require a
capture card and do not test device negotiation or Windows decoding transforms.

If you have an Elgato 4K X, also exercise the affected formats and resolutions
on hardware. Include the tested Windows version, GPU, driver, USB connection,
format, resolution, and frame rate in the pull request.

## Pull requests

- Keep changes focused and explain user-visible behavior.
- Preserve cleanup for every COM interface, handle, thread, and GPU resource.
- Do not add per-frame heap allocations or CPU frame conversions to native GPU
  paths.
- Keep capture callbacks non-blocking except for required GPU synchronization.
- Update the README and changelog when behavior, controls, requirements, or
  supported formats change.
- Avoid editing `vendor/` unless updating the complete vendored dependency and
  its license information.

## Reports without the hardware

Code, documentation, build-system, and static-analysis contributions do not
require a capture card. Clearly state when a change has only been build-tested
and still needs hardware verification.
