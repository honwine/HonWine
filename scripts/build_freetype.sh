#!/bin/bash
# build_freetype.sh — FreeType 交叉编译 (x86_64-linux-ohos)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

FT_SRC="$ROOT/thirdparty/freetype-VER-2-13-3"
FT_BUILD="$BUILD_DIR/freetype_build"
FT_INSTALL="$FT_BUILD/install"

log "=== 构建 FreeType (x86_64) ==="

mkdir -p "$FT_BUILD"
cd "$FT_BUILD"

cmake "$FT_SRC" \
    -GNinja \
    -DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake" \
    -DOHOS_ARCH=x86_64 \
    -DOHOS_PLATFORM=OHOS \
    -DCMAKE_BUILD_TYPE=Release \
    -DFT_DISABLE_BROTLI=ON \
    -DFT_DISABLE_HARFBUZZ=ON \
    -DFT_DISABLE_PNG=ON \
    -DFT_DISABLE_BZIP2=ON \
    -DCMAKE_INSTALL_PREFIX="$FT_INSTALL"

ninja
ninja install

log "FreeType 构建完成: $FT_INSTALL"
echo "  include: $FT_INSTALL/include/freetype2"
echo "  lib:     $(ls "$FT_INSTALL"/lib*/libfreetype* 2>/dev/null)"
echo "  export FT_INSTALL=$FT_INSTALL"
