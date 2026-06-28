# VirGL 显示链路优化评估记录

> 日期: 2026-06-28
>
> 目的: 记录本轮显示链路优化的实际改动、基准结果、当前瓶颈判断，以及合并后下一步推进方向。

## 结论摘要

本轮优化已经把最终显示链路里最明显的两类 CPU 拷贝拆开验证：

- `gl_compositor_direct` 已经移除 `TakeFrame -> CPU snapshot -> EglRenderer upload` 这段整帧快照拷贝。
- 本轮新增的 wl_shm dirty-rect commit copy 在局部刷新场景中生效，显著降低 commit copy。
- direct Wine 启动的 `winehua_graphics_smoke.exe` 仍然是整帧动态更新，`partial_upload=0`，所以帧率不明显变化是符合预期的。
- 当前 guest OpenGL 仍运行在 `virgl (softpipe)`，且日志显示 `LIBGL_ALWAYS_SOFTWARE=1`。模拟器上的慢主要应继续看作 guest 软件 3D 渲染 + 整帧提交/upload 共同导致，而不是单纯最终显示链路没有优化。

因此，当前可以认为显示链路已完成一个可合并的小步优化；下一阶段应区分两条线推进：

- 链路线: 继续减少 full-frame damage、commit copy 和 GL upload。
- 渲染线: 如果目标是判断真实 3D 性能，应准备真机测试，确认是否能脱离 `softpipe`。

## 本轮改动

### 1. Presenter 对照与强制选择

已经加入 benchmark presenter override：

- `auto`
- `cpu_shm_upload`
- `gl_compositor_direct`

ArkTS benchmark 参数会把 `presenter` 传到 native，native 侧通过 `GraphicsBroker::SetPresenterOverride()` 控制当前 presenter。这样可以在同一套 benchmark 中做 A/B 对照，而不是依赖启动环境变量。

相关文件：

- `entry/src/main/cpp/graphics_broker.*`
- `entry/src/main/cpp/backend_detector.*`
- `entry/src/main/cpp/napi_init.cpp`
- `entry/src/main/ets/pages/Index.ets`
- `scripts/graphics_benchmark.ps1`
- `scripts/graphics_benchmark_matrix.ps1`
- `scripts/write_graphics_evaluation.ps1`

### 2. GL compositor direct

`gl_compositor_direct` 让 embedded Wayland compositor 直接把 surface texture 合成到 XComponent EGLSurface，避免原来的：

```text
Wayland compositor
  -> TakeFrame
  -> CPU full-frame snapshot
  -> EglRenderer upload
  -> XComponent
```

当前 direct 路径变成：

```text
Wayland wl_surface
  -> SurfaceTextureCache
  -> GL compositor
  -> XComponent EGLSurface
```

这一阶段不等于零拷贝。它仍然存在：

```text
wl_shm commit -> CPU surface cache -> glTexImage2D/glTexSubImage2D
```

但已经去掉了合成后的 CPU snapshot 拷贝。

### 3. wl_shm dirty-rect commit copy

本轮新增的是 commit 阶段的保守局部拷贝：

- 在 `surface_commit` 中先 normalize damage rect。
- 只有在以下条件全部满足时，才按 damage rect 局部复制：
  - surface 像素缓存已经存在并且大小匹配；
  - buffer 宽高不变；
  - content 宽高不变；
  - content offset 不变；
  - shm format 不变；
  - damage 面积小于整面。
- 其他情况仍走 full copy。
- `AddSurfaceCommitBytes()` 记录实际复制字节数，而不是无条件记录整面字节数。

相关文件：

- `entry/src/main/cpp/wayland_server.cpp`
- `entry/src/main/cpp/wayland_server.h`

这个策略的目标不是让 direct smoke 立刻提帧，而是让局部更新场景不再每次 commit 都复制整面 surface。

## 基准结果

### 构建与部署

验证环境：

- Target: `127.0.0.1:5555`
- Arch: `x86_64`
- Backend: `msys2`
- Build: `scripts/rebuild_harmony.ps1 -Backend msys2 -Mode incremental -Arch x86_64 -SkipInstall -SkipLaunch -SkipLogs`
- Deploy: `scripts/rebuild_harmony.ps1 -Mode deploy -Target 127.0.0.1:5555 -SkipLaunch -SkipLogs`

结果：

- 增量构建通过。
- HAP 部署成功。

### 既有 A/B 结论

评估报告：

- `out/graphics-benchmarks/graphics-benchmark-matrix-20260628-052808-evaluation.md`
- `out/graphics-benchmarks/graphics-benchmark-matrix-20260628-052808.json`

direct Wine 启动 `winehua_graphics_smoke.exe` 的 A/B 中位数：

| presenter | runs | full uploads | commit MB | snapshot MB | total CPU MB | GL upload MB | present ms |
|---|---:|---:|---:|---:|---:|---:|---:|
| `cpu_shm_upload` | 2 | 117 | 234.69 | 489.93 | 724.62 | 242.88 | 47.06 |
| `gl_compositor_direct` | 2 | 201 | 397.78 | 0.00 | 397.78 | 396.79 | 15.71 |

结论：

- `gl_compositor_direct` 把 snapshot copy 降到 0。
- present time 下降约 66.61%。
- total CPU copy 按 run total 下降约 45.10%，按每次 upload 下降约 68.05%。
- GL upload total 变大，是因为 GL direct 在同样时间窗口内跑出了更多帧。

### 本轮 direct GL 复测

命令：

```powershell
.\scripts\graphics_benchmark.ps1 `
  -Target 127.0.0.1:5555 `
  -HdcPath "D:\Work\WineHua\out\sdk-links\harmonyos-sdk-root\HarmonyOS-6.0.33\openharmony\toolchains\hdc.exe" `
  -Mode graphics-direct `
  -Presenter gl_compositor_direct `
  -Seconds 16 `
  -Iterations 1 `
  -WaitSeconds 140
```

结果：

- JSON: `out/graphics-benchmarks/graphics-benchmark-20260628-071551.json`
- hilog: `out/graphics-benchmarks/graphics-benchmark-20260628-071551.hilog.txt`

| metric | value |
|---|---:|
| finished | true |
| timedOut | false |
| commit_count | 263 |
| commit_copy_mb | 518.35 |
| snapshot_copy_mb | 0.00 |
| gl_upload_mb | 518.35 |
| full_upload | 262 |
| partial_upload | 0 |
| damage_rects | 260 |
| avg_present_ms | 5.60 |
| avg_upload_ms | 1.73 |

解释：

- direct smoke 是动态整帧 3D 内容，merged damage 仍接近整帧。
- 因为 `partial_upload=0`，本轮 dirty-rect commit copy 不会显著降低 direct smoke 的 commit/upload 总量。
- 所以用肉眼看帧率不明显变化，不能说明本轮优化无效；它说明当前 direct smoke 的瓶颈不是局部 commit copy。

### 本轮 explorer 观察样本

命令：

```powershell
.\scripts\graphics_benchmark.ps1 `
  -Target 127.0.0.1:5555 `
  -HdcPath "D:\Work\WineHua\out\sdk-links\harmonyos-sdk-root\HarmonyOS-6.0.33\openharmony\toolchains\hdc.exe" `
  -Mode graphics-explorer `
  -Presenter gl_compositor_direct `
  -Seconds 10 `
  -Iterations 1 `
  -WaitSeconds 120
```

结果：

- JSON: `out/graphics-benchmarks/graphics-benchmark-20260628-071837.json`
- hilog: `out/graphics-benchmarks/graphics-benchmark-20260628-071837.hilog.txt`

| metric | value |
|---|---:|
| sampled | true |
| timedOut | false |
| commit_count | 49 |
| commit_copy_mb | 2.24 |
| snapshot_copy_mb | 0.00 |
| full_upload | 1 |
| partial_upload | 47 |
| damage_rects | 47 |
| damage_px | 12,784 |
| merged_damage_px | 312,912 |
| avg_present_ms | 20.34 |
| avg_upload_ms | 2.36 |

对比此前 explorer/multi-window 观察样本：

- 旧观察样本: `commit_copy_mb` 约 55.85，`partial_upload=43`。
- 新观察样本: `commit_copy_mb=2.24`，`partial_upload=47`。

解释：

- explorer 不是当前主基线，因为 direct Wine 启动 smoke 更可靠。
- 但它能触发局部刷新，所以适合作为 dirty-rect commit copy 的观察样本。
- 该结果说明本轮 commit-copy 优化在局部刷新场景中生效。

### CPU fallback 校验

命令：

```powershell
.\scripts\graphics_benchmark.ps1 `
  -Target 127.0.0.1:5555 `
  -HdcPath "D:\Work\WineHua\out\sdk-links\harmonyos-sdk-root\HarmonyOS-6.0.33\openharmony\toolchains\hdc.exe" `
  -Mode graphics-direct `
  -Presenter cpu_shm_upload `
  -Seconds 8 `
  -Iterations 1 `
  -WaitSeconds 100
```

结果：

- JSON: `out/graphics-benchmarks/graphics-benchmark-20260628-072223.json`
- hilog: `out/graphics-benchmarks/graphics-benchmark-20260628-072223.hilog.txt`

| metric | value |
|---|---:|
| presenter | `cpu_shm_upload` |
| timedOut | false |
| snapshot_count | 238 |
| commit_copy_mb | 229.02 |
| gl_upload_mb | 240.52 |
| full_upload | 119 |
| partial_upload | 0 |
| avg_present_ms | 30.74 |

结论：

- fallback 路径仍可用。
- 本轮 `surface_commit` 改动没有破坏 `cpu_shm_upload`。

### 排除样本

`out/graphics-benchmarks/graphics-benchmark-20260628-071121.json` 不纳入性能结论。

原因：

- 该样本 direct smoke 被 benchmark timeout 杀掉。
- 只有 4 次 commit 和 1 次 full upload，不是可比的连续动画样本。
- 可作为启动/暖机异常参考，不作为优化收益依据。

## 当前瓶颈判断

### 显示链路已经改善的部分

已经改善：

- 合成后 CPU snapshot copy 已由 `gl_compositor_direct` 移除。
- 局部刷新场景下的 wl_shm commit copy 已由 dirty-rect copy 降低。
- fallback 路径仍保留，便于回归和兼容。

仍存在：

- direct dynamic smoke 仍是 full upload。
- direct smoke 的 damage merged 后接近整帧，`partial_upload=0`。
- `wl_shm -> GL texture` 仍有 CPU cache 和 GL upload，不是 NativeBuffer/EGLImage 或 scanout import。

### guest 3D 渲染仍是关键慢点

日志和打包脚本都显示当前 guest 3D 仍是软件渲染路径：

```text
LIBGL_ALWAYS_SOFTWARE=1
MESA_LOADER_DRIVER_OVERRIDE=swrast
GALLIUM_DRIVER=virpipe
```

运行日志中也能看到：

```text
EGL-MAIN: debug: Found 'LIBGL_ALWAYS_SOFTWARE' set, will use a CPU renderer
renderer=virgl (softpipe)
```

因此，模拟器上帧率不明显改善，不能只归因于最终显示链路。更合理的解释是：

```text
guest software 3D rendering
  + dynamic full-frame damage
  + wl_shm commit copy
  + GL full upload
```

其中前两项对 direct smoke 的影响最大。

## 合并建议

本轮适合合并的内容：

- `GraphicsStats`、presenter 抽象和 benchmark presenter override。
- `CpuShmPresenter` fallback。
- `GlCompositorPresenter` 和 `SurfaceTextureCache`。
- `wl_shm` dirty-rect commit copy。
- benchmark 脚本和报告生成脚本。

合并时需要保持的原则：

- `cpu_shm_upload` 必须继续作为 fallback。
- direct Wine 启动 `winehua_graphics_smoke.exe` 继续作为主基线。
- explorer/multi-window 只能作为兼容性和局部刷新观察样本，不能作为主性能结论。
- 不要在当前阶段把 NativeBuffer/EGLImage 作为默认路径，先保留为后续能力验证。
- 不要把 VirGL 命令路径已接通误解为最终显示零拷贝。

建议合并前最小复测：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Backend msys2 `
  -Mode incremental `
  -Arch x86_64 `
  -SkipInstall `
  -SkipLaunch `
  -SkipLogs

powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\rebuild_harmony.ps1 `
  -Mode deploy `
  -Target 127.0.0.1:5555 `
  -HdcPath "D:\Work\WineHua\out\sdk-links\harmonyos-sdk-root\HarmonyOS-6.0.33\openharmony\toolchains\hdc.exe" `
  -SkipLaunch `
  -SkipLogs

.\scripts\graphics_benchmark.ps1 `
  -Target 127.0.0.1:5555 `
  -HdcPath "D:\Work\WineHua\out\sdk-links\harmonyos-sdk-root\HarmonyOS-6.0.33\openharmony\toolchains\hdc.exe" `
  -Mode graphics-direct `
  -Presenter gl_compositor_direct `
  -Seconds 16 `
  -Iterations 1 `
  -WaitSeconds 140

.\scripts\graphics_benchmark.ps1 `
  -Target 127.0.0.1:5555 `
  -HdcPath "D:\Work\WineHua\out\sdk-links\harmonyos-sdk-root\HarmonyOS-6.0.33\openharmony\toolchains\hdc.exe" `
  -Mode graphics-direct `
  -Presenter cpu_shm_upload `
  -Seconds 8 `
  -Iterations 1 `
  -WaitSeconds 100
```

## 下一步推进

### Step 1: 让统计更容易用于短样本

问题：

- 当前 `GraphicsStats` 按帧间隔输出，短样本或异常样本有时不够稳定。

建议：

- 增加 end-of-run stats flush。
- benchmark 结束时主动输出一次最终累计值。
- 保留按 interval 输出，便于观察趋势。

验收：

- 8s `cpu_shm_upload` 和 16s `gl_compositor_direct` 都能稳定拿到最终统计。

### Step 2: 继续分析 direct smoke 为什么 full-frame damage

问题：

- direct smoke 中 `damage_rects` 不为空，但 merged damage 接近整帧，最终仍 `partial_upload=0`。

建议：

- 在 damage 统计中增加：
  - raw damage rect count；
  - clipped damage area；
  - merged damage area；
  - full-upload threshold 命中原因；
  - surface 尺寸和 content offset。
- 确认是应用每帧真的 damage 全屏，还是 compositor/geometry 映射把小 rect 合并成了大 rect。

验收：

- direct smoke 每帧 full upload 的原因可以从日志直接读出来。

### Step 3: 如果存在小 rect 被过度合并，再优化 damage 合并策略

当前 `SurfaceTextureCache` 会把多个 damage rect 合并成一个 bounding rect。对于分散的小 rect，这可能扩大上传面积。

建议：

- 保持当前单 merged rect 策略作为默认。
- 增加阈值：当多个 rect 的总面积远小于 merged bounding rect 时，逐个 `glTexSubImage2D` 上传。
- 限制 rect 数量，避免大量小 rect 造成 GL 调用开销反而变大。

验收：

- 局部刷新样本中 `gl_upload_mb` 下降。
- direct full-frame 样本不退化。

### Step 4: 真机测试判断 guest 3D 上限

触发条件：

- emulator 上 direct smoke 仍由 `virgl (softpipe)` 主导；
- 显示链路已经去掉 snapshot copy，并证明局部刷新 commit copy 可下降；
- 继续在 emulator 上优化末端 copy 对帧率改善有限。

真机测试重点：

- guest renderer 是否仍是 `virgl (softpipe)`。
- 是否还能看到 `LIBGL_ALWAYS_SOFTWARE=1`。
- host EGL/GLES 是否能提供硬件路径。
- direct benchmark 的 `avg_present_ms`、`avg_upload_ms`、`commit_copy_mb`、`gl_upload_mb` 是否变化。

建议真机对照矩阵：

| 场景 | presenter | 目的 |
|---|---|---|
| direct smoke | `gl_compositor_direct` | 主 3D 性能观察 |
| direct smoke | `cpu_shm_upload` | fallback 对照 |
| explorer observation | `gl_compositor_direct` | 局部刷新链路观察 |

判定：

- 如果真机仍是 `softpipe`，优先继续研究 guest Mesa/renderer 路径，而不是显示末端零拷贝。
- 如果真机脱离 `softpipe`，再扩大 direct benchmark，并开始评估 NativeBuffer/EGLImage 的收益。

### Step 5: NativeBuffer/EGLImage 只做能力验证，不急着默认启用

建议顺序：

1. 探测 HarmonyOS app 侧 NativeBuffer/EGLImage 能力。
2. 记录 EGL extension、buffer handle/fd、同步 fence 的可用性。
3. 做最小 demo 验证 import 到 GL texture。
4. 再决定是否接入 presenter。

验收：

- 有清晰 capability 日志。
- import 失败时不会影响 `cpu_shm_upload` 和 `gl_compositor_direct`。

## 当前推荐路线

短期：

```text
稳定 GL direct
  -> 补最终统计 flush
  -> 解释 direct full-frame damage
  -> 优化局部 damage 合并和上传策略
```

中期：

```text
真机测试 guest renderer
  -> 判断是否仍是 softpipe
  -> 决定继续 guest 3D 路径还是显示 buffer import
```

长期：

```text
NativeBuffer/EGLImage capability
  -> VirGL resource / scanout import 可行性研究
  -> 接近零拷贝显示
```
