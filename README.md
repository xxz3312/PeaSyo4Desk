<p align="center">
  <a href="https://github.com/Geocld/PeaSyo">
    <img src="https://raw.githubusercontent.com/Geocld/PeaSyo/main/images/logo.png" width="100">
  </a>
</p>
<p align="center">
  <a href="https://github.com/Geocld/PeaSyo">
    <img src="https://raw.githubusercontent.com/Geocld/PeaSyo/main/images/logo-text.png" width="300">
  </a>
</p>

<p align="center">
  PlayStation remote play client, PeaSyo desktop client for windows/macOS/Linux(steamOS).
</p>

> **Windows on ARM fork:** This is an unofficial fork of [Geocld/PeaSyo4Desk](https://github.com/Geocld/PeaSyo4Desk) focused on native Windows ARM64 builds. Credit for the original project belongs to its upstream maintainers.

**English** | [中文](./README.zh_CN.md)

## Windows on ARM64

Download the `win-arm64` ZIP from [Releases](https://github.com/xxz3312/PeaSyo4Desk/releases), extract the **entire** archive, and run `PeaSyo4Desk.exe`. Node.js is not required on the target PC. Keep the included native modules and DLLs together. The package includes ARM64 Chiaki and SDL2 bindings and ARM64 VC runtime files; FFmpeg runs as an x64 child process through Windows on ARM compatibility.

The app has been confirmed to launch, detect a controller, and stream successfully on a Windows on ARM device. The Chiaki binding lacks some of the original desktop `remote.*` APIs; internet remote connection has not been verified separately and may be unavailable. See [ARM64 build notes](./ARM64-BUILD-NOTES.md).

This fork checks upstream `main` daily. When a new commit merges cleanly, it builds and publishes a Windows ARM64 ZIP automatically. Sync conflicts and failed builds are reported in [Actions](https://github.com/xxz3312/PeaSyo4Desk/actions) without publishing a broken release. Both the sync and build workflows can also be started manually.

## Intro

PeaSyo, also known as Pixiu, is a PS4/5 streaming application for Android that supports remote wake-up, remote streaming, button mapping, controller vibration, and other rich features. You can play your PS anywhere using your phone, tablet, or handheld device.

> DISCLAIMER: PeaSyo is not affiliated with Sony, PlayStation. All rights and trademarks are property of their respective owners.

> Notice: PeaSyo is only compatible with PS4 systems running firmware version 8.0 or higher

## Features

- Support for multiple console registration
- Support for local and remote streaming
- Up to 1080P resolution with HDR support
- Support gamepad vibration
- Support for button mapping
- Streaming performance monitoring
- Remote wakeup and standby
- AMD FidelityFX SUPER RESOLUTION v1 [FSR 1]

<img src="https://raw.githubusercontent.com/Geocld/PeaSyo4Desk/main/images/consoles.png" width="600" />
<img src="https://github.com/Geocld/PeaSyo4Desk/blob/main/images/stream.png" width="600" />

## Steam Deck

### Installing from Flathub
`PeaSyo` is now available on Flathub. You can directly search for `PeaSyo` in the application store (Discover) in desktop mode on your Steam Deck to install and receive future updates.

[![Build/release](https://flathub.org/assets/badges/flathub-badge-en.svg)](https://flathub.org/apps/io.github.Geocld.PeaSyo4Desk)

## Local Development

### Requirements
- [NodeJs](https://nodejs.org/) >= 22
- [Yarn](https://yarnpkg.com/) >= 1.22

### Steps to get up and running

Clone the repository:

```
git clone https://github.com/xxz3312/PeaSyo4Desk
cd PeaSyo4Desk
```

Install dependencies:

```
yarn
```

Run development build:

```
npm run dev
```

## LICENSE
PeaSyo strictly follows the [AGPL v3 License]((./LICENSE)). If other projects reference or use implementations from this project, please strictly comply with this license.
