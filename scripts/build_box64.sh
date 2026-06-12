#!/bin/bash
# build_box64.sh — Box64 ARM64 交叉编译
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

log "=== 构建 Box64 ==="

# 应用补丁 (已应用则跳过)
cd "$BOX64_SRC"
git am --abort 2>/dev/null || true
rm -rf "$ROOT/.git/modules/thirdparty/box64/rebase-apply" 2>/dev/null || true
if ! git log --oneline -10 | grep -q "ohos:"; then
    git am "$PATCHES_DIR/box64/"*.patch || true
fi

# CMake + Ninja (ninja 自行处理增量)
mkdir -p "$BUILD_DIR/box64_build"
cd "$BUILD_DIR/box64_build"
cmake "$BOX64_SRC" \
    -GNinja \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake" \
    -DOHOS_ARCH=arm64-v8a \
    -DOHOS_PLATFORM=OHOS \
    -DCMAKE_BUILD_TYPE=Release \
    -DARM_DYNAREC=ON \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON
ninja box64

log "Box64 构建完成"
