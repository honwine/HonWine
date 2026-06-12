#!/bin/bash
# build_wine.sh — Wine 交叉编译
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

# Wine 编译标志 (Unix .so + wineserver)
WINE_CFLAGS="-g -O2 -D__MUSL__ -D_GNU_SOURCE -D__ANDROID__ -DWINE_UNIX_LIB \
    -D_NTSYSTEM_ -D__WINESRC__ -DFAR= -D_ACRTIMP= -DWINBASEAPI= -DZ_SOLO \
    -fPIC -fasynchronous-unwind-tables"

build_native_tools() {
    log "--- Native 构建 (winegcc + PE DLLs) ---"
    mkdir -p "$WINE_SRC/build-native"
    cd "$WINE_SRC/build-native"
    if [ ! -f "Makefile" ]; then
        ../configure --enable-win64 --disable-tests \
            --without-x --without-freetype --without-alsa \
            --without-opengl --without-vulkan
    fi
    make -j$JOBS
}

build_freetype() {
    log "--- 构建 FreeType ---"
    local ft_src="$ROOT/thirdparty/freetype-VER-2-13-3"
    local ft_build="$BUILD_DIR/freetype_build"
    local ft_install="$ft_build/install"

    if [ -f "$ft_install/lib/libfreetype.so" ]; then
        log "FreeType 已编译，跳过"
        return
    fi

    mkdir -p "$ft_build"
    cd "$ft_build"
    cmake "$ft_src" \
        -GNinja \
        -DCMAKE_TOOLCHAIN_FILE="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake" \
        -DOHOS_ARCH=x86_64 \
        -DOHOS_PLATFORM=OHOS \
        -DCMAKE_BUILD_TYPE=Release \
        -DFT_DISABLE_BROTLI=ON \
        -DFT_DISABLE_HARFBUZZ=ON \
        -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_BZIP2=ON \
        -DBUILD_SHARED_LIBS=ON \
        -DCMAKE_INSTALL_PREFIX="$ft_install"
    ninja
    ninja install
    log "FreeType 完成: $ft_install"
}

build_ohos_unix() {
    log "--- OHOS 交叉编译 (Unix .so) ---"
    local ft_install="$BUILD_DIR/freetype_build/install"

    mkdir -p "$WINE_SRC/build-ohos"
    cd "$WINE_SRC/build-ohos"

    # 检查是否需要重新 configure (FreeType 启用/禁用 状态变更)
    if [ ! -f "Makefile" ] || ! grep -q '#define SONAME_LIBFREETYPE' include/config.h 2>/dev/null; then
        export FREETYPE_CFLAGS="-I$ft_install/include/freetype2"
        export FREETYPE_LIBS="-L$ft_install/lib -lfreetype"
        export ac_cv_header_ft2build_h=yes
        export ac_cv_lib_soname_freetype="libfreetype.so.6"

        CC="gcc" ../configure \
            --host=x86_64-linux-ohos \
            --prefix=/opt/winebox \
            --libdir='${prefix}' \
            --with-wine-tools=../build-native \
            --with-mingw=gcc \
            --disable-tests \
            --without-x --without-alsa \
            --without-opengl --without-vulkan
        sed -i 's/#define HAVE_LINUX_NTSYNC_H 1/\/\* OHOS \*\/\n#undef HAVE_LINUX_NTSYNC_H/' include/config.h
        sed -i 's/#define HAVE_NETIPX_IPX_H 1/\/\* OHOS \*\/\n#undef HAVE_NETIPX_IPX_H/' include/config.h
    fi

    make -k -j$JOBS \
        CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
        CFLAGS="$WINE_CFLAGS -I$ft_install/include/freetype2" \
        LDFLAGS="-fuse-ld=lld --sysroot=$SYSROOT --target=$TARGET -L$ft_install/lib" || true
}

build_wineserver() {
    log "--- 编译 wineserver (含 OHOS 修复) ---"
    local out="$BUILD_DIR/wine_server"
    local wine_include="-I$WINE_SRC/include -I$WINE_SRC/include/wine -I$WINE_SRC/server -I$WINE_SRC/build-ohos/include"
    local srv_cflags="--target=$TARGET --sysroot=$SYSROOT -D__MUSL__ -D_GNU_SOURCE \
        -DWINE_UNIX_LIB -D_NTSYSTEM_ -D__WINESRC__ -DFAR= -D_ACRTIMP= -DWINBASEAPI= -DZ_SOLO \
        -D__ANDROID__ -DBINDIR=\"/opt/winebox/bin\" -DDATADIR=\"/opt/winebox/share\" \
        -fPIC $wine_include"

    mkdir -p "$out"
    local need_rebuild=0
    if [ ! -f "$out/wineserver" ]; then
        need_rebuild=1
    else
        for f in $WINE_SRC/server/*.c; do
            [ "$f" -nt "$out/wineserver" ] && { need_rebuild=1; break; }
        done
    fi
    if [ $need_rebuild -eq 0 ]; then return; fi
    for f in $WINE_SRC/server/*.c; do
        $CLANG $srv_cflags -c -o "$out/$(basename "$f" .c).o" "$f"
    done

    # musl compat stub: epoll_pwait2
    cat > "$out/musl_compat.c" << 'EOF'
#define _GNU_SOURCE
#include <sys/epoll.h>
#include <errno.h>
int epoll_pwait2(int fd, struct epoll_event *ev, int n,
                 const struct timespec *ts, const sigset_t *s)
{ errno=ENOSYS; return -1; }
EOF
    $CLANG $srv_cflags -c -o "$out/musl_compat.o" "$out/musl_compat.c"

    $CLANG --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld \
        -o "$out/wineserver" "$out"/*.o -lm
    log "wineserver: $out/wineserver"
}

# ---- main ----
log "=== 构建 Wine ==="

# 应用补丁
cd "$WINE_SRC"
git am "$PATCHES_DIR"/*.patch 2>/dev/null || true

build_native_tools
build_freetype
build_ohos_unix
build_wineserver

log "Wine 构建完成"
