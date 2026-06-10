# Phase 2 预研: Wine on HarmonyOS ARM64

> **日期**: 2026-06-11
> **状态**: 预研阶段，ARM64 Unix 侧编译验证通过

---

## 1. 核心概念

Phase 2 需要**双重翻译**：

| 层次 | 翻译 | 工具 |
|------|------|------|
| CPU 指令 | x86_64 → ARM64 | FEX-Emu (ARM64EC) |
| CPU 指令 | x86_32 → ARM64 | Box64 (wowbox64.dll) |
| OS API | Windows → POSIX | Wine (原生 ARM64) |

**架构图**:
```
Windows x86_64 .exe  ──→  FEX ARM64EC  ──→  Wine ARM64 (原生)  ──→  OHOS Kernel
Windows x86 .exe      ──→  Box64 wow64   ──→  Wine ARM64 (原生)  ──→  OHOS Kernel
```

---

## 2. 编译验证 (2026-06-11)

### 2.1 ARM64 wineserver ✅
```
file:  ELF 64-bit LSB pie executable, ARM aarch64
interpreter: /lib/ld-musl-aarch64.so.1
NEEDED: libc.so
size:  966K
```

### 2.2 ARM64 ntdll/unix ✅ (15/21 编译通过)

6 个失败是因缺少 configure 生成的头文件 (`ntsyscalls.h`, `locale_private.h`, `SYSTEMDLLPATH` 等)，非 musl 兼容性问题。

### 2.3 构建命令

```bash
TARGET=aarch64-linux-ohos
CFLAGS="--target=$TARGET --sysroot=$SYSROOT
    -D__MUSL__ -D_GNU_SOURCE -DWINE_UNIX_LIB
    -D_NTSYSTEM_ -D__WINESRC__ -DFAR= -D_ACRTIMP= -DWINBASEAPI= -DZ_SOLO
    -fPIC -I$WINE/include -I$WINE/include/wine"
```

**结论**: Phase 1 的 x86_64 编译配方对 ARM64 完全适用，只需改 target triple。

---

## 3. 已有资源

| 组件 | 状态 | 说明 |
|------|------|------|
| Box64 on OHOS ARM64 | ✅ | Box64 OHOS 移植, 14/14 测试通过 |
| OHOS ARM64 SDK | ✅ | `aarch64-linux-ohos` 完整可用 |
| Wine ARM64 Unix 侧 | 🟡 | 编译基本可行，需完整 configure |
| Wine ARM64 PE DLLs | ⬜ | 需要 `aarch64-w64-mingw32` 工具链 |

---

## 4. Phase 2 待解决问题

### 4.1 PE 交叉编译
- **问题**: 需要 `aarch64-w64-mingw32-clang` (llvm-mingw ARM64)
- **影响**: 阻塞完整 Wine ARM64 构建
- **方案**: 安装 llvm-mingw for aarch64, 或使用 Hangover 的 by-laws 分支

### 4.2 FEX-Emu 的 musl 移植
- **问题**: FEX-Emu 依赖 glibc 内部机制 (signal, TLS, dlopen)
- **当前状态**: 无已知 musl port
- **替代方案**: Box64 也可处理 x86_64? (目前 Box64 主要处理 32-bit)

### 4.3 ARM64EC ABI
- **问题**: ARM64EC 是 Microsoft 定义的 ABI，用于混合 ARM64 原生和 x86_64 模拟代码
- **Hangover 方案**: `libarm64ecfex.dll` (FEX 实现)
- **OHOS 适配**: 需要确认 OHOS kernel 支持 ARM64EC 所需的特性

### 4.4 图形栈
- **问题**: OHOS 无 X11/Wayland
- **Phase 1 策略**: 仅控制台
- **Phase 2 策略**: Mesa zink (Vulkan → OpenGL) + OHOS 原生窗口

---

## 5. 技术路线建议

```
Phase 2a: 完整 Wine ARM64 编译
├── 获取 llvm-mingw aarch64
├── configure --host=aarch64-linux-ohos --enable-archs=arm64ec,aarch64,i386
├── 编译 ARM64 PE DLLs + Unix .so
└── 验证: wineserver --version on ARM64 device

Phase 2b: Box64 集成 (32-bit x86)
├── 已有 Box64 OHOS 移植
├── 编译 wowbox64.dll (Box64 as Wine PE DLL)
├── 验证: 运行 x86 Windows console app
└── 集成: HODLL=wowbox64.dll wine app.exe

Phase 2c: FEX 集成 (64-bit x86_64)
├── Port FEX to musl/OHOS
├── 编译 libarm64ecfex.dll
├── 验证: 运行 x86_64 Windows console app
└── 集成: HODLL64=libarm64ecfex.dll wine app.exe

Phase 2d: 图形栈
├── Mesa zink on OHOS
├── Wine Wayland driver (或 OHOS native)
└── 验证: 运行 Windows GUI 程序
```

---

## 6. 关键依赖和下载

| 工具 | URL | 用途 |
|------|-----|------|
| llvm-mingw (ARM64) | github.com/mstorsjo/llvm-mingw | PE 交叉编译 |
| by-laws llvm-mingw | github.com/bylaws/llvm-mingw | ARM64EC PE 交叉编译 |
| Box64 OHOS 移植 | 参考文档 OHOS 移植 | Box64 OHOS port 参考 |
| Hangover | github.com/AndreRH/hangover | Wine+Emu 集成方案 |
| FEX-Emu | github.com/FEX-Emu/FEX | x86_64→ARM64 模拟 |
