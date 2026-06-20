# Wine ARM64 Native 编译 + ARM64EC 仿真 移植方案

参考项目: HangOver (https://github.com/AndreRH/hangover)

## 总览

```
┌──────────────────────────────────────────┐
│  x86_64 Windows App (ARM64EC 仿真)        │  FEX/Box64-ARM64EC
├──────────────────────────────────────────┤
│  ARM64 Wine PE DLLs (aarch64-windows)    │  WoW64 层
│  ARM64 Wine Unix .so (aarch64-linux-ohos) │  native
├──────────────────────────────────────────┤
│  HarmonyOS ARM64                          │
└──────────────────────────────────────────┘
```

## 实现步骤

### Phase 1: 编译工具链准备

1. **aarch64-w64-mingw32 交叉编译器**（Wine PE DLL 编译必需）
   - 当前 OHOS SDK 不提供 mingw ARM64 交叉编译器
   - 方案A: 用 LLVM/clang 自建（`--target=aarch64-w64-mingw32`）
   - 方案B: 从 HangOver 参考其 mingw 构建方式
   - 输出: `/opt/mingw-aarch64/bin/aarch64-w64-mingw32-gcc`

2. **OHOS ARM64 sysroot 扩展**（依赖库）
   - FreeType, Wayland, xkbcommon 交叉编译为 aarch64-linux-ohos
   - 安装到 `build/sysroot-ext/usr/lib/aarch64-linux-ohos/`

### Phase 2: 构建脚本改造

3. **scripts/env.sh** — 架构参数化
   - `TARGET` 从 `NATIVE_ARCH` 推导: `arm64-v8a` → `aarch64-linux-ohos`
   - `SYSROOT_EXT_LIB` 参数化为 `$SYSROOT_EXT/usr/lib/$TARGET`

4. **scripts/build_wine.sh** — ARM64 configure + 编译
   - `--host=aarch64-linux-ohos`
   - `--enable-archs=aarch64,x86_64`（WoW64: PE 端支持两种架构）
   - `aarch64_CC=/opt/mingw-aarch64/bin/aarch64-w64-mingw32-gcc`
   - Unix .so 生成路径: `build-ohos/dlls/*/xxx.so` (ARM64 ELF)
   - PE .dll 生成路径: `build-ohos/dlls/*/aarch64-windows/` + `x86_64-windows/`

5. **scripts/build_deps.sh** — ARM64 依赖
   - build_freetype/wayland/xkbcommon 增加 aarch64-linux-ohos target
   
6. **scripts/assemble.sh** — ARM64 布局
   - Unix .so → `libs/arm64-v8a/` (不再走 rawfile zip)
   - PE .dll → rawfile `bin/aarch64-windows/` + `bin/x86_64-windows/`
   - **跳过 Box64 构建**

### Phase 3: ARM64EC 仿真器集成

7. **ARM64EC 仿真层**
   - 参考 HangOver 的 `libarm64ecfex.dll`（FEX 集成为 PE DLL）
   - Wine 的 ARM64EC 机制: 应用入口为 x86_64，Windows API 调用时切换到 ARM64 原生
   - 需要编译 FEX 或 Box64 为 OHOS ARM64 原生 .so
   - 作为 `libarm64ecfex.dll` 放入 `bin/aarch64-windows/`

### Phase 4: Wine 代码适配

8. **OHOS ARM64 兼容修复**（预计少量）
   - `dlls/ntdll/unix/signal_arm64.c` — 确认 OHOS musl 信号兼容
   - `dlls/ntdll/unix/virtual.c` — ARM64EC map 在 OHOS 上的 mmap 兼容
   - PAD_MODE 代码（process.c/loader.c）已在原生代码中，ARM64 同样适用

### Phase 5: 测试

9. **x86_64 Windows 应用验证**
   - wineboot --init
   - notepad
   - explorer /desktop

## 风险

| 风险 | 影响 | 缓解 |
|------|------|------|
| aarch64 mingw 交叉编译器构建 | 阻塞 PE DLL 编译 | 用 LLVM/clang 自建，参考 HangOver |
| ARM64 WoW64 在 Linux 上不够成熟 | x86_64 应用兼容性 | 重点功能聚焦，逐步适配 |
| OHOS musl + ARM64 信号兼容 | 崩溃 | 已有 signal_arm64.c，只需验证 |
| FEX 移植到 OHOS | 仿真器核心 | Box64 已有 OHOS 移植经验，可复用 |
