# WineHua 当前状态

> 更新日期: 2026-06-22

## 已验证主线

### 构建链路

- WSL 构建链可用
- Windows DevEco / OpenHarmony SDK 可复用
- `x86_64` HNP 和已签名 HAP 可持续产出
- 推荐入口仍然是:
  - `scripts/rebuild_harmony.ps1`
  - `scripts/rebuild_harmony.sh`

### 运行链路

- HarmonyOS `2in1 / pc_all` 模拟器可安装并启动应用
- HAP 进程内嵌 Wayland compositor 可启动
- `wineserver` 可启动
- `wineboot --init` 可无人值守推进
- `notepad.exe` 可启动

### UI / 渲染 / 输入

- Wine toplevel 可映射为多个 `WineWindowAbility`
- `XComponentController + surfaceId` 渲染链路可用
- Wayland -> native renderer -> HarmonyOS 窗口链路可用
- 鼠标、键盘、多窗口基础行为已打通

### 音频链路

当前已验证的音频主线是:

```text
Win32 app
  -> Wine mmdevapi
  -> wineohos.drv
  -> host AudioBroker
  -> OHAudio
  -> 扬声器
```

已经确认的事实:

- `wineohos.drv` 已接入 `mmdevapi` 默认驱动优先级
- 宿主侧 broker、共享内存 ring、OHAudio renderer 已接通
- 最小冒烟样例 `winehua_audio_smoke.exe` 可运行
- `Alarm01.wav` 样例已经可通过 Wine 音频栈真实出声

## 当前默认假设

### 1. 当前最稳的验证目标仍然是 `x86_64`

当前优先目标是:

- `x86_64` Wine 用户态
- `x86_64` native libs
- HarmonyOS `2in1` PC 模拟器

`arm64` 仍然走同一套脚本和打包逻辑，但运行侧验证强度还没有 `x86_64` 这条主线高。

### 2. Mono / Gecko 首次交互安装仍然默认关闭

运行时默认设置:

```text
WINEDLLOVERRIDES=mscoree,mshtml=
```

目的:

- 让前缀初始化无人值守完成
- 避免 `Wine Mono Installer` 阻塞基础路径

影响:

- `.NET` / `mshtml` 依赖程序不是当前默认支持目标

### 3. HNP 运行时布局仍然以 `bin/` 为中心

当前运行时仍以这些目录布局为准:

- `opt/winehua/bin/ntdll.so`
- `opt/winehua/bin/x86_64-unix/*`
- `opt/winehua/bin/x86_64-windows/*`
- `opt/winehua/lib/<abi>/*`
- `opt/winehua/share/X11/xkb/*`

## 当前音频边界

### 已支持

- render only
- 一个默认播放设备
- shared mode
- 宿主侧多 stream 混音
- 常见共享模式 PCM 统一转换到固定 mix format

### 当前固定策略

- 宿主 mix format: `48kHz / stereo / s16le`
- backend 对外 `GetMixFormat()` 固定返回这组参数
- backend 内部当前接受:
  - `22050 / 44100 / 48000`
  - `mono / stereo`
  - `s16 / float32`

### 尚未支持

- capture / microphone
- exclusive mode
- 多声道输出
- 更复杂 PCM 格式

### 这里需要特别记住

- 驱动只负责 PCM 桥接
- MP3 / MP4 / 视频音轨能否成功播放，不由 `wineohos.drv` 单独决定
- 真正的多媒体验证，要同时看“上层是否能解码成 PCM”和“PCM 桥是否正常出声”

## 已经收口的关键问题

### 构建 / 工具链侧

- `rebuild_harmony.sh` / `rebuild_harmony.ps1` 已统一入口
- `incremental` / `wine` / `package` 模式已可区分使用

### 运行 / 打包侧

- PE 运行时从 `thirdparty/wine/build-ohos` 正确打包
- `WINEDLLPATH` 已回到 `bin/` 布局
- 音频 broker 已整合进现有 app native 进程
- `winehua_audio_smoke.exe` 和 `Alarm01.wav` 已作为最小验证材料纳入产物

## 仍然存在的限制

### 1. `.NET` / `mshtml` 应用仍不是当前目标

这是当前刻意保留的边界，不是偶发回归。

### 2. Wayland 可选协议仍未补齐

当前仍缺少一批可选能力，例如:

- pointer constraints
- relative pointer
- text input manager v3
- data device manager
- toplevel icon manager

这会直接影响:

- 剪贴板
- 相对鼠标移动
- 指针锁定
- 输入法集成
- 部分窗口外观能力

### 3. 音频桥接还需要继续打磨长时间与多格式验证

当前已经“能出声”，但还没有把所有验证做完。后续重点包括:

- 多进程同时播放的长时间稳定性
- MP3 / WAV / 视频音轨等多格式验证
- underrun / overflow 统计是否符合预期
- 未使用音频的进程是否始终不会被音频初始化拖慢

### 4. 事件回调路径还有进一步优化空间

当前 event-driven 客户端的唤醒依赖 `GET_STATUS` 轮询和 notify thread。

这条路径已经可用，但还不是最终形态。后续如果要进一步降低控制面开销，可以继续朝“更少轮询、更少状态查询”方向收口。

## TODO

### Merge Before PR

- [ ] Soak test: single-process, dual-process, repeated start/stop
- [ ] Format matrix: `Alarm01.wav`, `MP3`, other `WAV`, video audio track
- [ ] Check metrics: `underrun / overflow / queued_frames`
- [ ] Confirm non-audio Wine processes are not noticeably slowed by broker init

### Deferred Features

- [ ] capture / microphone
- [ ] exclusive mode
- [ ] multichannel output
- [ ] broader PCM format negotiation
- [ ] reduce `GET_STATUS` polling on the event-callback path

## Next

- Re-run the current smoke samples and confirm no regression in basic playback
- Test `MP3` and other containers, and distinguish decode failure from PCM bridge failure
- Run dual-process or multi-stream playback and inspect mixing plus underrun stats
- If OHAudio later becomes the bottleneck, continue with deeper event-driven optimization
