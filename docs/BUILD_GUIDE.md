# WineHua 构建指南

> 更新日期: 2026-06-22

这份文档只讲“当前最快、最稳、最容易复现”的构建路径，不再展开历史研究过程。

如果你是第一次接手这个仓库，先读 [ONBOARDING.md](ONBOARDING.md)。

## 结论先说

当前推荐入口有两个:

- Windows 宿主机一键入口: `scripts/rebuild_harmony.ps1`
- WSL 内单 shell 构建入口: `scripts/rebuild_harmony.sh`

如果只是想快速重建并装到设备/模拟器，优先用 `rebuild_harmony.ps1`。

## 支持的架构

- `x86_64`: 当前已在 HarmonyOS `2in1 / pc_all` 模拟器上验证通过，`notepad.exe` 可启动。
- `arm64`: 走同一套脚本和打包逻辑，适合真机/ARM64 设备。
- `all`: 双架构一起打包，主要用于产物完整性验证或后续发版准备。

脚本层面对 `arm64` 和 `x86_64` 不再分叉，只有 `box64` 这一步会按架构条件执行:

- `x86_64`: 不需要真实 Box64 二进制，HNP 内放 passthrough wrapper。
- `arm64` / `all`: 会额外执行 `build.sh box64`。

## 音频构建说明

当前主线音频实现已经切到:

```text
wineohos.drv -> host AudioBroker -> OHAudio
```

这意味着:

- 当前主线构建不需要额外同步外部音频运行时
- 音频能力跟随仓库内代码与宿主 OHAudio 路径一起构建
- 音频桥接层只负责 PCM 播放，不负责 MP3 / MP4 解码

当前会随产物一起打进去的最小音频验证材料主要是:

- `winehua_audio_smoke.exe`
- `Alarm01.wav`

它们用于验证“Wine 音频栈真实出声”，而不是只验证宿主侧 OHAudio 自测。

如果后续为了深挖音频问题，需要临时打开更详细的 Wine 音频日志，当前默认值位于:

- `entry/src/main/cpp/napi_init.cpp`

也可以通过 `WINEHUA_WINEDEBUG` 覆盖默认 `WINEDEBUG`。

## 快速开始

### 1. 首次完整构建并安装到 PC 模拟器

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode full `
  -Arch x86_64 `
  -Target 127.0.0.1:5555
```

### 2. 日常增量重建

适合改了 `entry/src/main/cpp`、ArkTS、`assemble.sh`、`package.sh`、签名或 HAP 侧配置之后使用:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode incremental `
  -Arch x86_64 `
  -Target 127.0.0.1:5555
```

### 2.1 只重编 Wine 再重新打包

适合只改了 `thirdparty/wine/`，不想把 native / deps 一起重来时使用:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode wine `
  -Arch x86_64 `
  -Target 127.0.0.1:5555
```

### 3. 只重新打包当前产物

适合只改了 HNP/HAP 组装逻辑，底层 native/Wine 产物不需要重编时使用:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode package `
  -Arch x86_64 `
  -Target 127.0.0.1:5555
```

### 4. 只重装当前 HAP

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode deploy `
  -Target 127.0.0.1:5555
```

### 5. 只看日志

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode logs `
  -Target 127.0.0.1:5555
```

### 6. 只做环境体检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode doctor `
  -Arch x86_64
```

## WSL 内部构建入口

如果只想在 WSL 里生成产物，不做安装/启动，可以直接跑:

```bash
bash scripts/rebuild_harmony.sh doctor x86_64
bash scripts/rebuild_harmony.sh full x86_64
bash scripts/rebuild_harmony.sh incremental x86_64
bash scripts/rebuild_harmony.sh wine x86_64
bash scripts/rebuild_harmony.sh package x86_64
```

把 `x86_64` 换成 `arm64` 或 `all` 即可。

## `Mode` 该怎么选

- `full`
  - thirdparty 代码变了
  - `scripts/env.sh` 变了
  - `scripts/build_*` 变了
  - Wine/Box64/sysroot-ext 相关依赖变了
  - 换机器、换 SDK、换 WSL 后第一次重建

- `incremental`
  - `entry/src/main/cpp` 变了
  - ArkTS 页面/能力/窗口管理变了
  - `assemble.sh`、`package.sh`、签名逻辑变了
  - 只是想快速确认最近代码能不能出 HAP
  - 如果前置产物缺失，脚本会自动补齐必要的 `deps` / `wine` / `box64`

- `wine`
  - 只改了 `thirdparty/wine/` 或 Wine 内置测试程序
  - 希望保留已有 `deps/native` 产物，只重做 Wine -> HNP -> HAP
  - 如果前置产物齐全，这是当前最快的 Wine 侧验证路径

- `package`
  - 只改了 HNP/HAP 组装路径、打包内容、ABI 过滤、签名流程
  - 底层编译产物理论上不需要重算
  - 但如果脚本发现前置产物缺失，会自动补齐所需步骤，因此第一次执行可能退化成比预期更重的构建

- `deploy`
  - 当前 HAP 已经存在，只想重装/重启

- `logs`
  - 当前应用已经装好，只想抓 `hilog`

如果你明确知道前置产物已经齐了，希望脚本不要“自动补齐”并意外退化成大构建，可以给 Windows 入口额外加 `-NoAutoHeal`，或给 WSL 入口加 `--no-auto-heal`。

- `doctor`
  - 想先确认工具链、submodule、`hdc` 目标和 SDK 路径是否健康

## 这两个新脚本做了什么

### `scripts/rebuild_harmony.sh`

- 统一构建入口，按 `Mode + Arch` 组合调度 `build.sh`
- 强校验顶层 submodule
- 对缺失的递归可选 submodule 给 warning，不误报成硬错误
- 把完整构建链路放在同一个 WSL shell 里执行
- 在 `incremental` / `package` 模式下自动补齐缺失的前置产物:
  - 缺 `sysroot-ext` 时自动补 `deps`
  - 缺 Wine 产物时自动补 `wine`
  - 缺 ARM64 Box64 产物时自动补 `box64`
  - 缺 `entry/libs/<abi>` 时自动补 `native`

### `scripts/rebuild_harmony.ps1`

- 在 Windows 宿主机上统一调 WSL 构建、`hdc install`、`aa start`、`hilog`
- 自动解析 `hdc.exe` 路径
- `-Target auto` 时会自动选择唯一在线目标
- `-Target <ip:port>` 时会尝试 `hdc tconn`
- 支持 `-SkipInstall`、`-SkipLaunch`、`-SkipLogs`

## 必要前提

### WSL 侧工具

至少需要这些包:

```bash
sudo apt-get update
sudo apt-get install -y \
  build-essential git pkg-config cmake ninja-build meson \
  zip unzip python3 perl default-jre autoconf automake libtool \
  bison flex gcc-mingw-w64-x86-64 g++-mingw-w64-x86-64
```

### Windows 侧工具

默认从以下位置解析 DevEco / OpenHarmony SDK:

- `C:\Program Files\Huawei\DevEco Studio`
- `D:\Program Files\Huawei\DevEco Studio`

关键工具包括:

- `hvigorw`
- `node.exe`
- `java.exe`
- `hnpcli.exe`
- `hdc.exe`

### 源码

顶层 submodule 需要初始化:

```bash
git submodule update --init --recursive
```

说明:

- `thirdparty/freetype/subprojects/dlg` 当前即使没有初始化，也只会在 `doctor` 里告警，不会阻塞已验证过的主线构建。

## 关键坑位

### 1. 不要把构建拆成多个独立的 WSL 调用

这是当前最容易踩的坑。

症状:

- `deps` 刚构建完是好的
- 过一会儿单独跑 `hnp` / `hap`，`build/` 里的中间产物像“消失”了一样

规避方式:

- 一律通过 `rebuild_harmony.sh` 或 `rebuild_harmony.ps1` 跑
- 让 `deps -> wine -> native -> hnp -> hap` 保持在同一个 WSL shell 内完成

### 2. 不要默认相信设备目标只有一个

如果同时挂着真机和模拟器，`hdc` 很容易装错设备。

规避方式:

- 多目标场景显式传 `-Target`
- PC 模拟器推荐直接写 `127.0.0.1:5555`

### 3. 当前默认关闭 Mono/Gecko 首次交互安装

为了让 `wineboot --init` 无人值守完成，运行时默认加了:

```text
WINEDLLOVERRIDES=mscoree,mshtml=
```

好处:

- 不会再被 `Wine Mono Installer` 阻塞
- `notepad.exe` / `cmd.exe` 这类基础路径更稳

代价:

- `.NET` / `mshtml` 依赖程序当前不是默认支持目标

### 4. `package.sh` 会临时改 ABI 过滤，但退出时会恢复

这是刻意设计的，目的是:

- 产出只带目标 ABI 的 HAP
- 不把 `entry/build-profile.json5` 永久改脏

## 当前默认产物路径

- 已签名 HAP:
  - `entry/build/default/outputs/default/entry-default-signed.hap`

- HNP:
  - `entry/hnp/x86_64/winehua.hnp`
  - `entry/hnp/arm64-v8a/winehua.hnp`

## 建议验收顺序

### 构建验收

- `doctor` 能跑通
- `entry-default-signed.hap` 存在
- 目标架构的 `winehua.hnp` 存在

### 安装验收

- `hdc install -r` 成功
- `aa start -b app.hackeris.winehua -a EntryAbility` 成功

### 运行验收

- `wineserver` 能启动
- `wineboot --init` 不再被 Mono 窗口卡住
- `notepad.exe` 能启动

## 底层命令还在，什么时候直接用 `build.sh`

只有在这些场景才建议回到 `build.sh`:

- 你在排查单个底层步骤，例如 `build_wine.sh` 自己为什么失败
- 你在修改脚本，需要精确知道是哪一步挂掉
- 你想手动复现 `rebuild_harmony.sh` 内部的子步骤

除此之外，优先走统一入口脚本。
