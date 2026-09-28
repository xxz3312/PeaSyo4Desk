# PeaSyo4Desk Windows ARM64 build notes

Source baseline: Geocld/PeaSyo4Desk commit
`84b90125a055d46d22d41eec4065d6b1d664c673`.

## What this changes

- The local `peasyo-lib` loader now selects `win32-arm64-msvc`.
- FFmpeg resolution uses the bundled x64 executable on Windows ARM64. FFmpeg
  runs as a child process, so it does not need to match Electron's architecture.
- `scripts/build-win-arm64.ps1` prepares an experimental local build using
  chiaki-lib, SDL2 and the matching node-sdl binding.

## Prerequisites

Use Windows ARM64 and an ARM64 Native Tools command prompt with ARM64 Node.js,
Yarn 1, Visual C++ ARM64 tools, Python 3, CMake, Ninja, Git and protoc. Install
vcpkg and bootstrap it before running:

```powershell
.\scripts\build-win-arm64.ps1 -VcpkgRoot C:\src\vcpkg
```

The script installs ARM64 OpenSSL, curl and zlib with vcpkg, compiles
`chiaki-lib` against the Electron version in the app, builds SDL2 and
`@kmamal/sdl` 0.11.13 for ARM64, modifies the installed
`peasyo-sdl-lib` platform selector, supplies an x64 FFmpeg child executable,
and creates `dist\win-arm64-unpacked`.

## Known limits

- The application has launched and detected a controller on a user's Windows
  on ARM device. Console registration and live streaming still need testing.
- The supplied `chiaki-lib` is not the same implementation as the desktop
  application's `peasyo-lib`. Its Node binding lacks the
  `remote.listDevices`, `remote.prepareConnection`,
  `remote.prepareSession`, and `remote.autoRegist` APIs. Online remote
  connection will need a port or an alternative compatible ARM64
  `peasyo-lib` build. Local discovery, registration and streaming also need
  a real Windows ARM64 smoke test.
- `node-hid` is rebuilt by `electron-builder install-app-deps`; verify the
  resulting `.node` and controller access on the target machine.
- All `.node` files and SDL2.dll must be ARM64 PE binaries. An x64 FFmpeg.exe
  is the sole deliberate x64 dependency in this workflow.

Inspect the machine type on Windows with `dumpbin /headers FILE | findstr /i
"AA64 machine"` and test the package on a Windows ARM64 computer with a
console and controller.
