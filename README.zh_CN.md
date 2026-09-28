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
  PeaSyo桌面客户端，支持windows/macOS/Linux(steamOS)。
</p>

> **Windows on ARM 分支**：本仓库是 [Geocld/PeaSyo4Desk](https://github.com/Geocld/PeaSyo4Desk) 的非官方 fork，主要提供 Windows ARM64 原生构建。原作者及上游项目请见原仓库。

## Windows on ARM64

在 [Releases](https://github.com/xxz3312/PeaSyo4Desk/releases) 下载名称包含 `win-arm64` 的 ZIP，**完整解压**后运行 `PeaSyo4Desk.exe`；无需单独安装 Node.js。请勿混用旧版本中的 `.node` 或 DLL。ARM64 构建包含 Chiaki 原生模块、SDL2 手柄模块及 ARM64 VC 运行库，FFmpeg 子进程使用 Windows on ARM 的 x64 兼容能力。

已在 Windows on ARM 设备上确认应用可以启动并识别手柄。PS4/PS5 实际串流尚未在此 fork 中验证；当前 Chiaki 模块缺少上游桌面版的部分 `remote.*` 接口，互联网远程连接可能无法使用。详情见 [ARM64 构建说明](./ARM64-BUILD-NOTES.md)。

本 fork 每天检查上游 `main`；有新提交且可以无冲突合并时，自动构建并发布 Windows ARM64 ZIP。同步冲突或构建失败会在 [Actions](https://github.com/xxz3312/PeaSyo4Desk/actions) 显示，不会发布失败版本。你也可以手动运行 `Sync upstream` 或 `Windows ARM64 build and release` 工作流。

## Intro

PeaSyo，也称貔貅（pixiu），使用中国古代神兽命名，是一款PS4/5串流应用，支持远程唤醒、远程串流、按键映射、手柄振动等丰富的功能，你可以在任意Android设备上使用貔貅游玩PlayStation游戏。


> 声明: PeaSyo与Sony、PlayStation没有关联。所有权和商标属于其各自所有者。

> 注意: 如果你使用貔貅串流PS4，你的主机系统固件版本需要升级到8+。

## 功能

- 支持多主机注册
- 支持本地串流和远程串流
- 最高支持1080P，支持HDR
- 支持按键映射
- 支持串流性能查看
- 支持快捷菜单
- 远程唤醒及休眠
- AMD FidelityFX SUPER RESOLUTION v1 [FSR 1]

<img src="https://raw.githubusercontent.com/Geocld/PeaSyo4Desk/main/images/consoles.png" width="600" />
<img src="https://github.com/Geocld/PeaSyo4Desk/blob/main/images/stream.png" width="600" />

## Steam Deck

### 从Flathub安装
`PeaSyo`已经上架Flathub，你可以直接在SteamDeck的桌面模式，使用应用商店（Discover）直接搜索`PeaSyo`即可下载安装和后续的更新。

[![Build/release](https://flathub.org/assets/badges/flathub-badge-en.svg)](https://flathub.org/apps/io.github.Geocld.PeaSyo4Desk)

## 本地开发

### 环境要求
- [NodeJs](https://nodejs.org/) >= 22
- [Yarn](https://yarnpkg.com/) >= 1.22

### 运行项目

克隆本项目到本地:

```
git clone https://github.com/xxz3312/PeaSyo4Desk
cd PeaSyo4Desk
```
安装依赖:

```
yarn
```

启动开发模式:

```
npm run dev
```


## 开源协议

PeaSyo 严格遵循 [AGPL v3 协议](./LICENSE)，如其他项目借鉴本项目实现，请严格遵循此协议。
