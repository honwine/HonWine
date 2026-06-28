#!/bin/bash
# build_deps.sh — 编排所有交叉编译依赖 (freetype → wayland → xkbcommon)
# 所有产物安装到 build/sysroot-ext/，不污染 OHOS SDK
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

log "=== 构建模拟层交叉编译依赖 (Wine用, x86_64-linux-ohos) → sysroot-ext ==="

# 按依赖链顺序执行 (模拟层依赖, 始终 x86_64-linux-ohos)
bash "$SCRIPT_DIR/build_freetype.sh"
bash "$SCRIPT_DIR/build_libffi.sh"
bash "$SCRIPT_DIR/build_wayland.sh"
bash "$SCRIPT_DIR/build_xkbcommon.sh"
# XKB 键盘布局数据 (xkeyboard-config, Wine 键盘驱动依赖, 架构无关)
bash "$SCRIPT_DIR/build_xkbconfig.sh"

# Guest GPU Mesa/VirGL 库 (输出到 prebuilt/guest_gfx/)
# 前提: OHOS SDK + meson + wayland-scanner + wayland-protocols >= 1.38
# 若源码构建失败, 使用已有的 prebuilt/guest_gfx/ 作为回退。
if [ -d "$ROOT/thirdparty/mesa" ] && [ -d "$ROOT/thirdparty/libdrm" ] \
   && [ -d "$ROOT/thirdparty/wayland-protocols" ]; then
    log "=== 构建 guest_gfx (Mesa/VirGL) 从源码 ==="
    # 确保 stub hilog 头文件可用 (OHOS Native SDK 不含 hilog/log.h)
    mkdir -p "$SYSROOT_EXT_INC/hilog"
    [ -f "$SYSROOT_EXT_INC/hilog/log.h" ] || cat > "$SYSROOT_EXT_INC/hilog/log.h" << 'HILEOF'
#ifndef STUB_HILOG_LOG_H
#define STUB_HILOG_LOG_H
#include <stdio.h>
#include <stdarg.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef enum { LOG_DEBUG=3, LOG_INFO=4, LOG_WARN=5, LOG_ERROR=6, LOG_FATAL=7 } LogLevel;
#define LOG_APP 0
static inline int HiLogPrint(unsigned int d, unsigned int l, unsigned int t, const char *f, ...)
    __attribute__((format(printf,4,5)));
static inline int HiLogPrint(unsigned int d, unsigned int l, unsigned int t, const char *f, ...) {
    (void)d;(void)t; va_list va; va_start(va,f); vfprintf(stderr,f,va); va_end(va); return 0; }
#ifdef __cplusplus
}
#endif
#endif
HILEOF
    bash "$SCRIPT_DIR/build_ohos_guest_gfx.sh"
else
    err "thirdparty/mesa, libdrm 或 wayland-protocols 缺失, 无法构建 guest_gfx"
fi

# Native compositor 依赖 (wayland-server for HAP) 在 build.sh 中按架构单独调用:
#   bash scripts/build_native.sh

log "模拟层依赖就绪: $SYSROOT_EXT"
echo ""
find "$SYSROOT_EXT" -type f | sort
