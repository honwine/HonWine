# WineHua Onboarding

> 更新日期: 2026-06-21

这份文档给第一次接手 `WineHua` 的同学用。

目标不是解释所有研究背景，而是让你在 10 分钟内知道:

- 这个仓库现在主推哪条构建路径
- 你第一天应该跑哪些命令
- 改了什么代码该用什么模式重建
- 出问题时先看哪里，不要先怀疑错方向

## 先记住这三个事实

### 1. 统一入口优先

不要上来就手动拼 `build.sh`。

优先使用:

- Windows 宿主机: `scripts/rebuild_harmony.ps1`
- WSL 内部: `scripts/rebuild_harmony.sh`

### 2. 当前最稳主线是 `x86_64 + PC 模拟器`

当前已经验证通过的默认验收链路是:

- `x86_64` 构建
- HarmonyOS `2in1 / pc_all` 模拟器
- 应用可安装启动
- `notepad.exe` 可运行

### 3. 构建必须尽量保持在同一个 WSL shell

不要把 `deps / wine / native / hnp / hap` 拆成多个独立 WSL 调用。

统一入口脚本已经帮你兜住这个坑了，所以尽量不要绕开它们。

## 第一天建议顺序

### 第 1 步: 跑环境体检

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode doctor `
  -Arch x86_64
```

你应该看到:

- `OHOS_SDK`
- `HVIGORW`
- `NODE_BIN`
- `JAVA_BIN`
- `HNPCLI`
- `HDC`
- 一个可见的 `hdc` target，例如 `127.0.0.1:5555`

### 第 2 步: 做一次完整重建

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode full `
  -Arch x86_64 `
  -Target 127.0.0.1:5555
```

### 第 3 步: 确认运行主线

重点看三件事:

- HAP 是否安装成功
- `aa start` 是否成功
- 日志里 `wineserver` 和 `notepad.exe` 主链是否正常

如果只是想单独抓日志:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode logs `
  -Target 127.0.0.1:5555
```

## 改动类型和推荐模式

### 用 `incremental`

适用于这些改动:

- `entry/src/main/cpp`
- ArkTS 页面和窗口管理
- `assemble.sh`
- `package.sh`
- HAP 签名和打包配置

命令:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode incremental `
  -Arch x86_64 `
  -Target 127.0.0.1:5555
```

### 用 `full`

适用于这些改动:

- `thirdparty/`
- Wine fork
- Box64
- `scripts/env.sh`
- `scripts/build_*.sh`
- 换机器、换 SDK、换 WSL 后首次构建

### 用 `package`

适用于这些改动:

- 只改 HNP/HAP 组装
- 只改 ABI 过滤
- 只改签名逻辑

说明:

- 即使你选了 `package`，统一脚本也会在缺前置产物时自动补 `deps / wine / native / box64`
- 所以它可能比你想象得更重，但至少不会静默打出残包

## 代码怎么找

### 应用入口和交互

- `entry/src/main/ets/pages/Index.ets`
- `entry/src/main/ets/pages/WineWindow.ets`
- `entry/src/main/ets/service/WineWindowManager.ets`
- `entry/src/main/ets/entryability/WineWindowAbility.ets`

### NAPI 和 Wine 启动

- `entry/src/main/cpp/napi_init.cpp`

这里负责:

- `wineserver`
- `wineboot`
- `runWineExe`
- 运行时环境变量

### Wayland compositor / 渲染 / 输入

- `entry/src/main/cpp/wayland_server.cpp`
- `entry/src/main/cpp/plugin_manager.cpp`
- `entry/src/main/cpp/egl_renderer.cpp`
- `entry/src/main/cpp/input_manager.cpp`

### 构建和打包

- `scripts/env.sh`
- `scripts/assemble.sh`
- `scripts/package.sh`
- `scripts/rebuild_harmony.sh`
- `scripts/rebuild_harmony.ps1`
- `build.sh`

## 当前不要误判成回归的事情

### Mono / Gecko 没有默认开启

现在运行时默认加了:

```text
WINEDLLOVERRIDES=mscoree,mshtml=
```

这是故意的。

目的:

- 避免 `Wine Mono Installer` 阻塞前缀初始化
- 保证 `cmd.exe` / `notepad.exe` 主链稳定

所以:

- `.NET` 应用不通，不应第一时间当成这次主线回归
- `mshtml` 依赖程序不通，也不应当成当前默认失败

### Wayland 可选协议还没补齐

当前已知仍有限制:

- 剪贴板
- pointer lock
- relative pointer
- IME
- window icon

这些方向如果没动过，不要顺手当成新 bug。

## 常见排障顺序

### `doctor` 先失败

先看:

- DevEco Studio 路径是否变化
- WSL 里 `java / node / cmake / ninja / meson / zip` 是否都在
- 模拟器是否已经启动
- `hdc list targets` 是否能看到目标

### HAP 能打出来但运行异常

先看:

- `scripts/assemble.sh` 有没有把运行时布局放对
- `entry/build/default/outputs/default/entry-default-signed.hap` 是否是最新产物
- `wineboot` 是否又被交互安装器卡住
- `WINEDLLPATH` 和运行时 `bin/` 布局是否被改坏

### `package` 比预想更慢

这通常不是坏事，往往只是脚本在自动补前置产物。

## 交接给下一个人之前，至少确认这些

- 统一入口脚本还能跑 `doctor`
- 至少一个目标架构能产出已签名 HAP
- 当前主线目标能安装启动
- 文档里写的命令没有漂移
- 如果你改了流程，记得同步:
  - `docs/BUILD_GUIDE.md`
  - `docs/CURRENT_STATUS.md`
  - `.codex/skills/winehua-harmony-build`

## 下一步应该看什么

- 想构建: 看 [BUILD_GUIDE.md](BUILD_GUIDE.md)
- 想知道当前能力边界: 看 [CURRENT_STATUS.md](CURRENT_STATUS.md)
- 想改代码: 看 [ARCHITECTURE.md](ARCHITECTURE.md)
