# GL 产物与复现说明

> 更新日期: 2026-06-27

## 结论先说

- 当前 GL / VirGL Step 1 的 Wine 侧主改动已经可以回到 `thirdparty/wine -> winehua/wine:dev`
- 刚才截图里的 “WSL2 / TLS link problem” 不在 Wine，在 `thirdparty/mesa-ohos` + `scripts/build_ohos_guest_gfx.sh` 这条 guest_gfx 构建链
- `wine-1/ohos-port` 比 `wine dev` 多的只是 1 个音频冒烟后续提交: `6e55c4a4 feat: update audio smoke test with extended format support`
- 一句话概括: GL 主链路看 `wine dev`，WSL2/TLS 卡项看 `mesa-ohos`

## 当前运行链路

```text
Windows EXE
  -> Wine opengl32 / win32u / winewayland.drv
  -> guest_gfx bundle (Mesa virpipe / libEGL / libGLESv2)
  -> VTEST_SOCKET_NAME
  -> virgl_test_server
  -> libvirglrenderer
  -> host EGL/GLES
  -> Wayland compositor
  -> GraphicsBroker::TakeFrame
  -> EglRenderer
  -> Harmony XComponent
```

## 产物对应表

| 产物 | 目标位置 | 作用 | 主要来源代码 |
| --- | --- | --- | --- |
| `entry-default-signed.hap` | `entry/build/default/outputs/default/entry-default-signed.hap` | 最终安装包 | `scripts/package.sh` + `entry/` Hvigor/HAP 打包逻辑 |
| `winehua.hnp` | `entry/hnp/x86_64/winehua.hnp` | WineHua 运行时内核包 | `scripts/assemble.sh` 组装，`scripts/package.sh` 打包 |
| `wine` / `wineserver` / `ntdll.so` / `x86_64-unix/*` / `x86_64-windows/*` | HNP `bin/` 内 | Wine 运行时本体 | `thirdparty/wine/`，组装逻辑在 `scripts/assemble.sh` |
| `winehua_graphics_smoke.exe` | HNP `bin/x86_64-windows/`，并复制到 `C:\winehua_graphics_smoke.exe` | 真实 Windows OpenGL/3D 冒烟程序，可直接看画面和 FPS | `thirdparty/wine/programs/winehua_graphics_smoke/main.c`，安装逻辑在 `entry/src/main/cpp/napi_init.cpp` |
| `virgl_test_server` | HNP `bin/virgl_test_server` | host 侧 VirGL vtest server，接收 guest Mesa 命令 | `thirdparty/virglrenderer/vtest/*`，构建在 `scripts/build_native.sh`，组装在 `scripts/assemble.sh` |
| `libvirglrenderer.so.1` | HNP `bin/x86_64-unix/libvirglrenderer.so.1` | host 渲染器实现 | `thirdparty/virglrenderer/src/*`，构建在 `scripts/build_native.sh` |
| `guest_gfx/*` | HNP `bin/guest_gfx/` | guest 3D receiver bundle，提供 Mesa virpipe / EGL / GLES / DRI | `thirdparty/mesa-ohos` + `thirdparty/libdrm-ohos`，构建在 `scripts/build_ohos_guest_gfx.sh`，打包在 `scripts/build_guest_gfx.sh` |
| `winehua-guest-gfx.env` | `guest_gfx/winehua-guest-gfx.env` | 设置 guest receiver 的 Mesa / virpipe 运行时环境 | `scripts/build_guest_gfx.sh` 生成 |
| `BUILD_INFO.txt` | `guest_gfx/BUILD_INFO.txt` | 记录 Mesa / libdrm 源码路径、Git HEAD、构建时间 | `scripts/build_guest_gfx.sh` 生成 |

## 代码对应关键点

### 1. host 侧的调度与环境注入

- `entry/src/main/cpp/graphics_broker.cpp`
  - 决定当前是 `shm` 还是 `virgl`
  - 检查 `guest_gfx` 是否齐全
  - 启动 `virgl_test_server`
  - 向 Wine 注入 `WINEHUA_*` 和 `VTEST_SOCKET_NAME`
- `entry/src/main/cpp/napi_init.cpp`
  - 给 Wine 进程组装环境变量
  - 把 `winehua_graphics_smoke.exe` 安装到 Wine prefix
  - 运行 graphics smoke 时可临时切到 `virgl` 后端和 `force_gl`
- `entry/src/main/cpp/wine_child.cpp`
  - NCP/appspawn 子进程入口
  - 给 Wine / wineserver 还原必要环境变量

### 2. 最终上屏画面来自哪里

- `entry/src/main/cpp/wayland_server.*`
  - 接收 Wine 内部 Wayland surface 和图像
- `entry/src/main/cpp/egl_renderer.*`
  - 把捕获到的图像上屏到 Harmony `XComponent`
- 当前画面传输仍是 `wl_shm + cpu_copy + gl_upload`
  - 这说明 Step 1 已经跑通，但还不是 zero-copy

### 3. `wine dev` 与刚才截图问题的分界

- `winehua/wine:dev` 已经包含
  - OpenGL / VirGL guest probe
  - `winehua_graphics_smoke.exe`
  - OHOS audio backend 主支撑
- 刚才截图里需要继续看的，是
  - `scripts/build_ohos_guest_gfx.sh`
  - `thirdparty/mesa-ohos/meson.build`
  - `thirdparty/mesa-ohos/ohos/meson_cross_process64.py`
- 也就是说，切回 `wine dev` 不会把 TLS 问题“修好”，但也不会把已经跑通的 GL host/guest 主链路切坏

## 如何复现

### 1. 一次性复现整条链路

```powershell
git submodule update --init --recursive
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\bootstrap_msys2.ps1
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 -Backend msys2 -Mode full -Arch x86_64 -Target 127.0.0.1:5555
```

这条命令会依次完成:

- `deps`
- `wine`
- `native`
- `hnp`
- `hap`
- 安装到模拟器

### 2. 只重做 guest_gfx bundle

构建 guest Mesa / virpipe:

```bash
bash scripts/rebuild_harmony.sh guest-gfx x86_64
```

如果只想直接做 Mesa bundle:

```bash
bash scripts/build_ohos_guest_gfx.sh --platform wayland --mode virpipe
```

然后只重打包 / 重装:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 -Mode package -Arch x86_64 -Target 127.0.0.1:5555
```

### 3. 只重做 graphics smoke 程序

```bash
bash scripts/rebuild_harmony.sh wine-smoke x86_64
```

这会只重做 `programs/winehua_graphics_smoke/x86_64-windows/winehua_graphics_smoke.exe`，避免整个 Wine 全量重编。

### 4. 运行时验证

安装后，在 Wine 内运行:

```text
C:\winehua_graphics_smoke.exe --loop
```

看以下几点:

- 窗口是否正常出图
- 画面左上角是否有 `FPS`
- `stderr/hilog` 是否打出 `GL vendor / renderer / version`
- 环境变量是否显示 `requested=virgl active=virgl`

## 当前卡项与后续

- 宿主屏幕上屏路径仍是 `wl_shm + cpu_copy + gl_upload`
- `guest_gfx` 在 WSL2 构建路径已经通了大部分，如再遇到 `TLS` / `gl_dispatch` / visibility 卡项，优先看 `thirdparty/mesa-ohos`
- `wine dev` 可以作为 GL 主链路的正式基线，音频后续那个 `wine-1` 提交如果还要，可以后面再单独 cherry-pick 或重做 audio smoke
