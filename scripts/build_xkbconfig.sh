#!/bin/bash
# build_xkbconfig.sh 鈥?鏋勫缓 xkeyboard-config (XKB 閿洏甯冨眬鏁版嵁) 鈫?sysroot-ext
# xkb 鏁版嵁鏄灦鏋勬棤鍏崇殑閰嶇疆鏂囦欢, Wine 閿洏椹卞姩鍒濆鍖栦緷璧?
# 婧愮爜鏉ヨ嚜 thirdparty/xkeyboard-config (git submodule)
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/env.sh"

XKBC_SRC="$ROOT/thirdparty/xkeyboard-config"
XKBC_BUILD="$BUILD_DIR/xkeyboard-config_build"
XKBC_INSTALL="$BUILD_DIR/xkeyboard-config_install"

log "=== 鏋勫缓 xkeyboard-config (XKB 鏁版嵁) ==="

# 宸插氨缁垯璺宠繃
if [ -d "$SYSROOT_EXT_SHARE/X11/xkb" ] && [ -f "$SYSROOT_EXT_SHARE/X11/xkb/rules/xkb.dtd" ]; then
    log "xkeyboard-config 宸插氨缁? 璺宠繃"
    exit 0
fi

if [ ! -f "$XKBC_SRC/meson.build" ]; then
    err "xkeyboard-config 婧愮爜鏈壘鍒? 璇峰厛: git submodule update --init thirdparty/xkeyboard-config"
fi

# Windows checkout may leave helper scripts with CRLF, which breaks shebang execution in WSL.
find "$XKBC_SRC" -type f \( -name '*.py' -o -name '*.pl' \) -exec sed -i 's/\r$//' {} +

if [ -d /usr/share/X11/xkb ] && [ -f /usr/share/X11/xkb/rules/xkb.dtd ]; then
    log "澶嶇敤 WSL 宿主 xkb-data (/usr/share/X11/xkb)..."
    mkdir -p "$SYSROOT_EXT_SHARE/X11"
    rm -rf "$SYSROOT_EXT_SHARE/X11/xkb"
    cp -r /usr/share/X11/xkb "$SYSROOT_EXT_SHARE/X11/"
    log "xkeyboard-config 鈫?${SYSROOT_EXT_SHARE}/X11/xkb/"
    du -sh "$SYSROOT_EXT_SHARE/X11/xkb"
    exit 0
fi

# 鈹€鈹€ Meson 鏋勫缓 (绾暟鎹寘, 鏃犵紪璇? 鏃犻渶浜ゅ弶缂栬瘧宸ュ叿閾? 鈹€鈹€
log "閰嶇疆 xkeyboard-config..."
rm -rf "$XKBC_BUILD" "$XKBC_INSTALL"

meson setup "$XKBC_BUILD" "$XKBC_SRC" \
    --prefix=/usr \
    -Dxorg-rules-symlinks=false

# ninja compile: 鐢熸垚 rules 鏂囦欢 (rules-base, rules-evdev 绛?, 鏃犲疄闄呬簩杩涘埗缂栬瘧
log "缂栬瘧 (鐢熸垚 rules)..."
ninja -C "$XKBC_BUILD"

# 瀹夎鍒?BUILD_DIR 涓嬬殑涓存椂鐩綍 (涓嶇敤 /tmp)
log "瀹夎 xkeyboard-config..."
DESTDIR="$XKBC_INSTALL" meson install -C "$XKBC_BUILD"

# 澶嶅埗鍒?sysroot-ext
# meson install 鍒涘缓 X11/xkb 鈫?/usr/share/xkeyboard-config-2 鐨?symlink
# HNP 鎵撳寘涓嶆敮鎸?symlink, 鐩存帴灞曞紑涓哄疄闄呮枃浠?
mkdir -p "$SYSROOT_EXT_SHARE"
rm -rf "$SYSROOT_EXT_SHARE/X11/xkb" "$SYSROOT_EXT_SHARE/xkeyboard-config-2"
cp -r "$XKBC_INSTALL/usr/share/xkeyboard-config-2" "$SYSROOT_EXT_SHARE/"
cp -rL "$XKBC_INSTALL/usr/share/X11" "$SYSROOT_EXT_SHARE/"
rm -rf "$XKBC_INSTALL"

log "xkeyboard-config 鈫?${SYSROOT_EXT_SHARE}/X11/xkb/"
du -sh "$SYSROOT_EXT_SHARE/X11/xkb"
