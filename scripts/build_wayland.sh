#!/bin/bash
# build_wayland.sh 鈥?Wayland + wayland-protocols 浜ゅ弶缂栬瘧 鈫?sysroot-ext
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

WL_SRC="$ROOT/thirdparty/wayland"
WP_SRC="$ROOT/thirdparty/wayland-protocols"
WL_BUILD="$BUILD_DIR/wayland_build"

# Ensure a host-native wayland-scanner is available without requiring root.
SCANNER="$WAYLAND_SCANNER"
build_scanner() {
    if [ -x "$SCANNER" ]; then return 0; fi
    log "--- 缂栬瘧 wayland-scanner (native) ---"
    local host_build="$BUILD_DIR/wayland_native"
    rm -rf "$host_build"
    mkdir -p "$HOST_TOOLS_DIR"
    meson setup "$host_build" "$WL_SRC" \
        --prefix "$HOST_TOOLS_DIR" -Ddocumentation=false -Dtests=false --buildtype=release
    ninja -C "$host_build"
    meson install -C "$host_build"
    log "wayland-scanner: $SCANNER"
}

ensure_target_libffi() {
    local src="$ROOT/thirdparty/libffi"
    local build="$BUILD_DIR/libffi_build"

    if [ -f "$SYSROOT_EXT_LIB/libffi.so.8" ] && [ -f "$SYSROOT_EXT_INC/ffi.h" ] && [ -f "$SYSROOT_EXT_PC/libffi.pc" ]; then
        return 0
    fi

    log "--- libffi (for wayland) ---"
    mkdir -p "$SYSROOT_EXT_INC" "$SYSROOT_EXT_LIB" "$SYSROOT_EXT_PC" "$build"
    cd "$build"
    "$src/autogen.sh" 2>/dev/null || true
    CC="$CLANG --target=$TARGET --sysroot=$SYSROOT" \
    CFLAGS="-O2 -fPIC -D__MUSL__" \
    LDFLAGS="-fuse-ld=lld" \
    "$src/configure" --host=x86_64-unknown-linux-musl --prefix="$build/install" --disable-docs --disable-dependency-tracking
    make -j"$JOBS"
    make install
    cp "$build/install/lib/libffi.so.8.1.4" "$SYSROOT_EXT_LIB/libffi.so.8"
    cp "$build/install/lib/libffi.so.8.1.4" "$SYSROOT_EXT_LIB/libffi.so"
    cp "$build/install/include/ffi.h" "$SYSROOT_EXT_INC/"
    cp "$build/install/include/ffitarget.h" "$SYSROOT_EXT_INC/"
    cat > "$SYSROOT_EXT_PC/libffi.pc" << EOF
prefix=$SYSROOT_EXT/usr
includedir=\${prefix}/include
libdir=\${prefix}/lib/x86_64-linux-ohos
Name: libffi
Description: Library supporting Foreign Function Interfaces
Version: 3.4.6
Libs: -L\${libdir} -lffi
Cflags: -I\${includedir}
EOF
}

log "=== 鏋勫缓 Wayland (x86_64) ==="

if [ -f "$SYSROOT_EXT_LIB/libwayland-client.so" ] \
   && [ -f "$SYSROOT_EXT_LIB/libwayland-client.so.0" ] \
   && [ -f "$SYSROOT_EXT_LIB/libwayland-server.so" ] \
   && [ -f "$SYSROOT_EXT_LIB/libwayland-server.so.0" ] \
   && [ -f "$SYSROOT_EXT_INC/wayland-client.h" ] \
   && [ -f "$SYSROOT_EXT_INC/wayland-version.h" ] \
   && [ -f "$SYSROOT_EXT_PC/wayland-client.pc" ]; then
    log "Wayland 宸插氨缁紝璺宠繃"
    exit 0
fi

build_scanner
ensure_target_libffi

mkdir -p "$SYSROOT_EXT_INC" "$SYSROOT_EXT_LIB" "$SYSROOT_EXT_PC" "$SYSROOT_EXT_SHARE"
mkdir -p "$WL_BUILD"

# 1. 浜ゅ弶缂栬瘧 wayland (client + egl)
meson_build "$WL_BUILD/x86_64" "$WL_SRC" \
    -Ddocumentation=false -Dtests=false -Dscanner=false
ninja -C "$WL_BUILD/x86_64"

# 瀹夎 .so (鏂囦欢鍚?= SONAME)
cp "$WL_BUILD/x86_64/src/libwayland-client.so.0.22.0" "$SYSROOT_EXT_LIB/libwayland-client.so"
cp "$WL_BUILD/x86_64/src/libwayland-client.so.0.22.0" "$SYSROOT_EXT_LIB/libwayland-client.so.0"
cp "$WL_BUILD/x86_64/src/libwayland-server.so.0.22.0" "$SYSROOT_EXT_LIB/libwayland-server.so"
cp "$WL_BUILD/x86_64/src/libwayland-server.so.0.22.0" "$SYSROOT_EXT_LIB/libwayland-server.so.0"

# 澶存枃浠?
cp "$WL_SRC/src/wayland-client.h" \
   "$WL_SRC/src/wayland-client-core.h" \
   "$WL_SRC/src/wayland-util.h" \
   "$WL_BUILD/x86_64/src/wayland-version.h" \
   "$WL_BUILD/x86_64/src/wayland-client-protocol.h" \
   "$SYSROOT_EXT_INC/"

# 2. wayland-protocols
meson_build "$WL_BUILD/protocols" "$WP_SRC" \
    -Dtests=false
ninja -C "$WL_BUILD/protocols"

# 瀹夎鍗忚 XML 鍒?sysroot-ext
mkdir -p "$SYSROOT_EXT_SHARE/wayland-protocols/stable/xdg-shell" \
         "$SYSROOT_EXT_SHARE/wayland"
cp "$WP_SRC/stable/xdg-shell/xdg-shell.xml" "$SYSROOT_EXT_SHARE/wayland-protocols/stable/xdg-shell/"
cp "$WL_SRC/protocol/wayland.xml" "$SYSROOT_EXT_SHARE/wayland/"

# .pc 鏂囦欢
cat > "$SYSROOT_EXT_PC/wayland-client.pc" << EOF
prefix=$SYSROOT_EXT/usr
includedir=\${prefix}/include
libdir=\${prefix}/lib/x86_64-linux-ohos

Name: Wayland Client
Description: Wayland client side library
Version: 1.22.0
Requires.private: libffi
Libs: -L\${libdir} -lwayland-client
Cflags: -I\${includedir}
EOF

cat > "$SYSROOT_EXT_PC/wayland-protocols.pc" << EOF
prefix=$SYSROOT_EXT/usr
datarootdir=\${prefix}/share
pkgdatadir=\${datarootdir}/wayland-protocols
Name: Wayland Protocols
Description: Wayland protocol files
Version: 1.32
EOF

log "Wayland 鈫?sysroot-ext"
