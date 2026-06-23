#!/bin/bash
# Shared build environment. Source this file from other scripts.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

env_fail() {
    echo "[ERROR] $*" >&2
    return 1 2>/dev/null || exit 1
}

command_or_empty() {
    command -v "$1" 2>/dev/null || true
}

resolve_first_existing() {
    local candidate
    for candidate in "$@"; do
        [ -n "${candidate:-}" ] || continue
        if [ -e "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

resolve_first_executable() {
    local candidate
    for candidate in "$@"; do
        [ -n "${candidate:-}" ] || continue
        if [ -x "$candidate" ]; then
            printf '%s\n' "$candidate"
            return 0
        fi
    done
    return 1
}

maybe_prepend_path() {
    local dir="$1"
    [ -d "$dir" ] || return 0
    case ":$PATH:" in
        *":$dir:"*) ;;
        *) PATH="$dir:$PATH" ;;
    esac
}

remove_tree() {
    local path="$1"
    [ -e "$path" ] || return 0

    chmod -R u+w "$path" 2>/dev/null || true
    rm -rf "$path" 2>/dev/null || true
    [ ! -e "$path" ] && return 0

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$path" <<'PY'
import os
import shutil
import stat
import sys

path = sys.argv[1]

def onerror(func, target, exc_info):
    try:
        os.chmod(target, stat.S_IWRITE | stat.S_IREAD | stat.S_IEXEC)
    except OSError:
        pass
    try:
        func(target)
    except Exception:
        pass

if os.path.lexists(path):
    shutil.rmtree(path, onerror=onerror)
PY
    fi

    [ ! -e "$path" ] || env_fail "failed to remove directory: $path"
}

BUILD_DIR="${ROOT}/build"
SDK_LINK_DIR="${ROOT}/out/sdk-links"
HOST_TOOLS_DIR="${BUILD_DIR}/host-tools"
WRAPPER_DIR="${BUILD_DIR}/tool-wrappers"

DEFAULT_DEVECO_HOME="$(resolve_first_existing \
    "${DEVECO_HOME:-}" \
    /apps/harmony \
    "/mnt/c/Program Files/Huawei/DevEco Studio" \
    "/mnt/d/Program Files/Huawei/DevEco Studio" \
    || true)"
DEFAULT_OHOS_SDK="$(resolve_first_existing \
    "${DEFAULT_DEVECO_HOME:+$DEFAULT_DEVECO_HOME/sdk/default/openharmony}" \
    /apps/harmony/sdk/default/openharmony \
    "/mnt/c/Program Files/Huawei/DevEco Studio/sdk/default/openharmony" \
    "/mnt/d/Program Files/Huawei/DevEco Studio/sdk/default/openharmony" \
    || true)"

export OHOS_SDK="${OHOS_SDK:-}"
if [ -z "$OHOS_SDK" ]; then
    OHOS_SDK="$DEFAULT_OHOS_SDK"
fi
[ -n "$OHOS_SDK" ] || env_fail "OHOS SDK not found. Set OHOS_SDK or install DevEco/OpenHarmony SDK."
[ -d "$OHOS_SDK" ] || env_fail "OHOS SDK directory does not exist: $OHOS_SDK"

OHOS_SDK_SOURCE="$OHOS_SDK"
if [[ "$(realpath -m "$OHOS_SDK")" == "$(realpath -m "$SDK_LINK_DIR")/"* ]] \
   && [ -n "$DEFAULT_OHOS_SDK" ] && [ -d "$DEFAULT_OHOS_SDK" ]; then
    OHOS_SDK_SOURCE="$DEFAULT_OHOS_SDK"
fi
OHOS_SDK_PARENT="$(cd "$OHOS_SDK_SOURCE/../../.." && pwd)"
export DEVECO_HOME="${DEVECO_HOME:-$OHOS_SDK_PARENT}"
export TOOL_HOME="${TOOL_HOME:-$DEVECO_HOME}"
OHOS_BASE_SDK_HOME_REAL="$(cd "$OHOS_SDK_SOURCE" && pwd)"
DEVECO_SDK_HOME_REAL="$(cd "$OHOS_SDK_SOURCE/.." && pwd)"
ORIG_OHOS_BASE_SDK_HOME_REAL="$OHOS_BASE_SDK_HOME_REAL"
ORIG_DEVECO_SDK_HOME_REAL="$DEVECO_SDK_HOME_REAL"
SDK_PKG_JSON="$DEVECO_SDK_HOME_REAL/sdk-pkg.json"

export WSL_SDK_MAP_OHOS_FROM=""
export WSL_SDK_MAP_OHOS_TO=""
export WSL_SDK_MAP_HMS_FROM=""
export WSL_SDK_MAP_HMS_TO=""
export WSL_EXE_EXTRA_PATHS="${WSL_EXE_EXTRA_PATHS:-}"
export WSL_RESTOOL_PLUGIN_DIR="${WSL_RESTOOL_PLUGIN_DIR:-}"

if [ -f "$SDK_PKG_JSON" ] && command -v python3 >/dev/null 2>&1; then
    SDK_PKG_PATH="$(python3 - "$SDK_PKG_JSON" <<'PY'
import json
import sys

with open(sys.argv[1], "r", encoding="utf-8") as f:
    data = json.load(f)

print(data.get("data", {}).get("path", ""))
PY
)"
    if [ -n "$SDK_PKG_PATH" ] && [ ! -e "$DEVECO_SDK_HOME_REAL/$SDK_PKG_PATH/sdk-pkg.json" ]; then
        HOS_SDK_LINK_ROOT="$SDK_LINK_DIR/harmonyos-sdk-root"
        HOS_SDK_LAYOUT_DIR="$HOS_SDK_LINK_ROOT/$SDK_PKG_PATH"
        HOS_BISHENG_WRAPPER_DIR="$SDK_LINK_DIR/hms-bisheng-bin"
        HOS_HMS_LAYOUT_DIR="$HOS_SDK_LAYOUT_DIR/hms"
        HOS_HMS_NATIVE_LAYOUT_DIR="$HOS_HMS_LAYOUT_DIR/native"
        HOS_HMS_CMAKE_LAYOUT_DIR="$HOS_HMS_NATIVE_LAYOUT_DIR/build/cmake"
        HOS_OHOS_LAYOUT_DIR="$HOS_SDK_LAYOUT_DIR/openharmony"
        HOS_ETS_LAYOUT_DIR="$HOS_OHOS_LAYOUT_DIR/ets"
        HOS_ETS_LOADER_LAYOUT_DIR="$HOS_ETS_LAYOUT_DIR/build-tools/ets-loader"
        HOS_OHOS_TOOLCHAIN_DIR="$HOS_OHOS_LAYOUT_DIR/toolchains"
        HOS_NATIVE_LAYOUT_DIR="$HOS_OHOS_LAYOUT_DIR/native"
        HOS_NATIVE_LLVM_LAYOUT_DIR="$HOS_NATIVE_LAYOUT_DIR/llvm"
        HOS_CMAKE_LAYOUT_DIR="$HOS_NATIVE_LAYOUT_DIR/build-tools/cmake"

        mkdir -p "$HOS_SDK_LAYOUT_DIR"
        mkdir -p "$HOS_BISHENG_WRAPPER_DIR" "$HOS_HMS_CMAKE_LAYOUT_DIR" "$HOS_CMAKE_LAYOUT_DIR/bin" "$HOS_NATIVE_LAYOUT_DIR/build-tools"

        for tool in clang clang++ llvm-ar llvm-ranlib; do
            tool_src="$DEVECO_SDK_HOME_REAL/hms/native/BiSheng/bin/${tool}.exe"
            tool_wrapper="$HOS_BISHENG_WRAPPER_DIR/$tool"
            [ -e "$tool_src" ] || continue
            cat > "$tool_wrapper" <<EOF
#!/bin/bash
exec '$ROOT/scripts/wsl_exe_wrapper.sh' '$tool_src' "\$@"
EOF
            chmod +x "$tool_wrapper"
        done

        ln -sfn "$SDK_PKG_JSON" "$HOS_SDK_LAYOUT_DIR/sdk-pkg.json"

        for item in ets previewer toolchains NOTICE.txt; do
            [ -e "$DEVECO_SDK_HOME_REAL/hms/$item" ] || continue
            ln -sfn "$DEVECO_SDK_HOME_REAL/hms/$item" "$HOS_HMS_LAYOUT_DIR/$item"
        done

        for item in BinXO BiSheng docs sysroot nativeapi_syscap_config.json ndk_system_capability.json NOTICE.txt uni-package.json; do
            [ -e "$DEVECO_SDK_HOME_REAL/hms/native/$item" ] || continue
            ln -sfn "$DEVECO_SDK_HOME_REAL/hms/native/$item" "$HOS_HMS_NATIVE_LAYOUT_DIR/$item"
        done

        if [ -f "$DEVECO_SDK_HOME_REAL/hms/native/build/cmake/hmos.toolchain.cmake" ]; then
            ln -sfn "$DEVECO_SDK_HOME_REAL/hms/native/build/cmake/hmos.toolchain.cmake" "$HOS_HMS_CMAKE_LAYOUT_DIR/hmos.toolchain.cmake"
        fi

        if [ -f "$DEVECO_SDK_HOME_REAL/hms/native/build/cmake/hmos.toolchain.bisheng.cmake" ]; then
            python3 - "$DEVECO_SDK_HOME_REAL/hms/native/build/cmake/hmos.toolchain.bisheng.cmake" "$HOS_HMS_CMAKE_LAYOUT_DIR/hmos.toolchain.bisheng.cmake" "$HOS_BISHENG_WRAPPER_DIR" <<'PY'
import pathlib
import sys

src = pathlib.Path(sys.argv[1])
dst = pathlib.Path(sys.argv[2])
wrapper_dir = pathlib.Path(sys.argv[3])
text = src.read_text(encoding="utf-8")
replacements = {
    'set(CMAKE_C_COMPILER "${TOOLCHAIN_BIN_PATH}/clang${HOST_SYSTEM_EXE_SUFFIX}")': f'set(CMAKE_C_COMPILER "{wrapper_dir / "clang"}")',
    'set(CMAKE_CXX_COMPILER "${TOOLCHAIN_BIN_PATH}/clang++${HOST_SYSTEM_EXE_SUFFIX}")': f'set(CMAKE_CXX_COMPILER "{wrapper_dir / "clang++"}")',
    'set(OHOS_AR "${TOOLCHAIN_BIN_PATH}/llvm-ar${HOST_SYSTEM_EXE_SUFFIX}")': f'set(OHOS_AR "{wrapper_dir / "llvm-ar"}")',
    'set(OHOS_RANLIB "${TOOLCHAIN_BIN_PATH}/llvm-ranlib${HOST_SYSTEM_EXE_SUFFIX}")': f'set(OHOS_RANLIB "{wrapper_dir / "llvm-ranlib"}")',
}
for old, new in replacements.items():
    text = text.replace(old, new)
dst.write_text(text, encoding="utf-8")
PY
        fi

        for item in ets js previewer build compatible_config.json nativeapi_syscap_config.json ndk_system_capability.json NOTICE.txt oh-uni-package.json; do
            [ -e "$OHOS_SDK_SOURCE/$item" ] || continue
            [ "$item" = "ets" ] && continue
            ln -sfn "$OHOS_SDK_SOURCE/$item" "$HOS_OHOS_LAYOUT_DIR/$item"
        done

        mkdir -p "$HOS_OHOS_TOOLCHAIN_DIR"
        if [ -d "$OHOS_SDK_SOURCE/toolchains" ]; then
            toolchain_item=""
            for toolchain_item in "$OHOS_SDK_SOURCE/toolchains"/*; do
                [ -e "$toolchain_item" ] || continue
                toolchain_name="$(basename "$toolchain_item")"
                if [[ "$toolchain_name" == *.exe ]]; then
                    toolchain_base="${toolchain_name%.exe}"
                    ln -sfn "$toolchain_item" "$HOS_OHOS_TOOLCHAIN_DIR/$toolchain_name"
                    cat > "$HOS_OHOS_TOOLCHAIN_DIR/$toolchain_base" <<EOF
#!/bin/bash
exec '$ROOT/scripts/wsl_exe_wrapper.sh' '$toolchain_item' "\$@"
EOF
                    chmod +x "$HOS_OHOS_TOOLCHAIN_DIR/$toolchain_base"
                else
                    ln -sfn "$toolchain_item" "$HOS_OHOS_TOOLCHAIN_DIR/$toolchain_name"
                fi
            done
        fi

        for item in build docs llvm sysroot compatible_config.json nativeapi_syscap_config.json ndk_system_capability.json NOTICE.txt oh-uni-package.json; do
            [ -e "$OHOS_SDK_SOURCE/native/$item" ] || continue
            [ "$item" = "llvm" ] && continue
            ln -sfn "$OHOS_SDK_SOURCE/native/$item" "$HOS_NATIVE_LAYOUT_DIR/$item"
        done

        mkdir -p "$HOS_ETS_LAYOUT_DIR" "$HOS_ETS_LAYOUT_DIR/build-tools" "$HOS_ETS_LOADER_LAYOUT_DIR/bin/ark/build/bin" "$HOS_ETS_LOADER_LAYOUT_DIR/bin/ark"
        if [ -d "$OHOS_SDK_SOURCE/ets" ]; then
            ets_item=""
            for ets_item in "$OHOS_SDK_SOURCE/ets"/*; do
                [ -e "$ets_item" ] || continue
                ets_name="$(basename "$ets_item")"
                [ "$ets_name" = "build-tools" ] && continue
                ln -sfn "$ets_item" "$HOS_ETS_LAYOUT_DIR/$ets_name"
            done
        fi

        if [ -d "$OHOS_SDK_SOURCE/ets/build-tools" ]; then
            ets_build_tool=""
            for ets_build_tool in "$OHOS_SDK_SOURCE/ets/build-tools"/*; do
                [ -e "$ets_build_tool" ] || continue
                ets_build_name="$(basename "$ets_build_tool")"
                [ "$ets_build_name" = "ets-loader" ] && continue
                ln -sfn "$ets_build_tool" "$HOS_ETS_LAYOUT_DIR/build-tools/$ets_build_name"
            done
        fi

        if [ -d "$OHOS_SDK_SOURCE/ets/build-tools/ets-loader" ]; then
            src_ets_loader="$(realpath -m "$OHOS_SDK_SOURCE/ets/build-tools/ets-loader")"
            dst_ets_loader="$(realpath -m "$HOS_ETS_LOADER_LAYOUT_DIR")"
            ets_loader_stamp="$HOS_ETS_LOADER_LAYOUT_DIR/.codex-sync-stamp"
            if [ "$src_ets_loader" != "$dst_ets_loader" ]; then
                if [ ! -f "$ets_loader_stamp" ] || [ "$OHOS_SDK_SOURCE/ets/build-tools/ets-loader/package.json" -nt "$ets_loader_stamp" ]; then
                    mkdir -p "$HOS_ETS_LOADER_LAYOUT_DIR"
                    cp -a "$OHOS_SDK_SOURCE/ets/build-tools/ets-loader/." "$HOS_ETS_LOADER_LAYOUT_DIR/"
                fi
            fi
            loader_patch_file="$HOS_ETS_LOADER_LAYOUT_DIR/lib/fast_build/ark_compiler/common/process_ark_config.js"
            if [ -f "$loader_patch_file" ] && [ ! -w "$loader_patch_file" ]; then
                chmod u+w "$loader_patch_file" 2>/dev/null || true
            fi
            if [ -f "$loader_patch_file" ]; then
                python3 - "$loader_patch_file" <<'PY'
import pathlib
import re
import sys

path = pathlib.Path(sys.argv[1])
text = path.read_text(encoding="utf-8")
pattern = r"function processPlatformInfo\(e\)\{.*?const utProcessArkConfig"
replacement = (
    'function processPlatformInfo(e){var o=e.arkRootPath,r=_fs.default.existsSync(_path.default.join(o,"build-win"));'
    'r?(e.es2abcPath=_path.default.join(o,"build","bin","es2abc"),'
    'e.ts2abcPath=_path.default.join(o,"build-win","src","index.js"),'
    'e.mergeAbcPath=_path.default.join(o,"build","bin","merge_abc"),'
    'e.js2abcPath=_path.default.join(o,"build","bin","js2abc"),'
    'e.aotCompilerPath=_path.default.join(o,"build","bin","ark_aot_compiler"),'
    'e.bcObfuscatorPath=_path.default.join(o,"build","bin","panda_guard")):'
    '(0,_utils2.isMac)()?(e.es2abcPath=_path.default.join(o,"build-mac","bin","es2abc"),'
    'e.ts2abcPath=_path.default.join(o,"build-mac","src","index.js"),'
    'e.mergeAbcPath=_path.default.join(o,"build-mac","bin","merge_abc"),'
    'e.js2abcPath=_path.default.join(o,"build-mac","bin","js2abc"),'
    'e.aotCompilerPath=_path.default.join(o,"build-mac","bin","ark_aot_compiler"),'
    'e.bcObfuscatorPath=_path.default.join(o,"build-mac","bin","panda_guard")):'
    '((0,_utils2.isLinux)()||(0,_utils2.isHarmonyOs)())&&'
    '(e.es2abcPath=_path.default.join(o,"build","bin","es2abc"),'
    'e.ts2abcPath=_path.default.join(o,"build","src","index.js"),'
    'e.mergeAbcPath=_path.default.join(o,"build","bin","merge_abc"),'
    'e.js2abcPath=_path.default.join(o,"build","bin","js2abc"),'
    'e.aotCompilerPath=_path.default.join(o,"build","bin","ark_aot_compiler"),'
    'e.bcObfuscatorPath=_path.default.join(o,"build","bin","panda_guard"))}'
    'function processCompatibleVersion(e,o){var r=o.arkRootPath;'
    '_fs.default.existsSync(_path.default.join(r,"build-win"))?'
    '(r=_path.default.join(r,"build-win")):(r=(0,_ark_utils.getArkBuildDir)(r));'
    'e.minPlatformVersion&&"8"===e.minPlatformVersion.toString()&&'
    '(o.ts2abcPath=_path.default.join(r,"legacy_api8","src","index.js"),e.pandaMode=_ark_define.TS2ABC)}'
    'const utProcessArkConfig'
)
patched, count = re.subn(pattern, replacement, text, count=1, flags=re.S)
if count != 1:
    raise SystemExit("failed to patch processPlatformInfo in ets-loader")
path.write_text(patched, encoding="utf-8")
PY
            fi
            printf '%s\n' "$src_ets_loader" > "$ets_loader_stamp"
        fi

        if [ -d "$OHOS_SDK_SOURCE/ets/build-tools/ets-loader/bin/ark/build-win/bin" ]; then
            ets_tool_item=""
            mkdir -p "$HOS_ETS_LOADER_LAYOUT_DIR/bin/ark/build/bin"
            for ets_tool_item in "$OHOS_SDK_SOURCE/ets/build-tools/ets-loader/bin/ark/build-win/bin"/*; do
                [ -e "$ets_tool_item" ] || continue
                ets_tool_name="$(basename "$ets_tool_item")"
                if [[ "$ets_tool_name" == *.exe ]]; then
                    ets_tool_base="${ets_tool_name%.exe}"
                    ln -sfn "$ets_tool_item" "$HOS_ETS_LOADER_LAYOUT_DIR/bin/ark/build/bin/$ets_tool_name"
                    cat > "$HOS_ETS_LOADER_LAYOUT_DIR/bin/ark/build/bin/$ets_tool_base" <<EOF
#!/bin/bash
exec '$ROOT/scripts/wsl_exe_wrapper.sh' '$ets_tool_item' "\$@"
EOF
                    chmod +x "$HOS_ETS_LOADER_LAYOUT_DIR/bin/ark/build/bin/$ets_tool_base"
                else
                    ln -sfn "$ets_tool_item" "$HOS_ETS_LOADER_LAYOUT_DIR/bin/ark/build/bin/$ets_tool_name"
                fi
            done
        fi

        mkdir -p "$HOS_NATIVE_LLVM_LAYOUT_DIR/bin"
        if [ -d "$OHOS_SDK_SOURCE/native/llvm" ]; then
            llvm_item=""
            for llvm_item in "$OHOS_SDK_SOURCE/native/llvm"/*; do
                [ -e "$llvm_item" ] || continue
                llvm_name="$(basename "$llvm_item")"
                [ "$llvm_name" = "bin" ] && continue
                ln -sfn "$llvm_item" "$HOS_NATIVE_LLVM_LAYOUT_DIR/$llvm_name"
            done
        fi

        if [ -d "$OHOS_SDK_SOURCE/native/llvm/bin" ]; then
            llvm_bin_item=""
            for llvm_bin_item in "$OHOS_SDK_SOURCE/native/llvm/bin"/*; do
                [ -e "$llvm_bin_item" ] || continue
                llvm_bin_name="$(basename "$llvm_bin_item")"
                if [[ "$llvm_bin_name" == *.exe ]]; then
                    llvm_bin_base="${llvm_bin_name%.exe}"
                    ln -sfn "$llvm_bin_item" "$HOS_NATIVE_LLVM_LAYOUT_DIR/bin/$llvm_bin_name"
                    cat > "$HOS_NATIVE_LLVM_LAYOUT_DIR/bin/$llvm_bin_base" <<EOF
#!/bin/bash
exec '$ROOT/scripts/wsl_exe_wrapper.sh' '$llvm_bin_item' "\$@"
EOF
                    chmod +x "$HOS_NATIVE_LLVM_LAYOUT_DIR/bin/$llvm_bin_base"
                else
                    ln -sfn "$llvm_bin_item" "$HOS_NATIVE_LLVM_LAYOUT_DIR/bin/$llvm_bin_name"
                fi
            done
        fi

        if [ -d "$OHOS_SDK_SOURCE/native/build-tools" ]; then
            local_bt=""
            for local_bt in "$OHOS_SDK_SOURCE/native/build-tools"/*; do
                [ -e "$local_bt" ] || continue
                base_bt="$(basename "$local_bt")"
                [ "$base_bt" = "cmake" ] && continue
                ln -sfn "$local_bt" "$HOS_NATIVE_LAYOUT_DIR/build-tools/$base_bt"
            done
        fi

        for item in bin/cmake.exe bin/cmake-gui.exe bin/cmcldeps.exe bin/cpack.exe bin/ctest.exe bin/ninja.exe doc man share; do
            src_item="$OHOS_SDK_SOURCE/native/build-tools/cmake/$item"
            dst_item="$HOS_CMAKE_LAYOUT_DIR/$item"
            [ -e "$src_item" ] || continue
            mkdir -p "$(dirname "$dst_item")"
            ln -sfn "$src_item" "$dst_item"
        done

        cat > "$HOS_CMAKE_LAYOUT_DIR/bin/cmake" <<'EOF'
#!/bin/bash
exec /usr/bin/cmake "$@"
EOF
        cat > "$HOS_CMAKE_LAYOUT_DIR/bin/ninja" <<'EOF'
#!/bin/bash
exec /usr/bin/ninja "$@"
EOF
        chmod +x "$HOS_CMAKE_LAYOUT_DIR/bin/cmake" "$HOS_CMAKE_LAYOUT_DIR/bin/ninja"

        export WSL_SDK_MAP_OHOS_FROM="$HOS_OHOS_LAYOUT_DIR"
        export WSL_SDK_MAP_OHOS_TO="$ORIG_OHOS_BASE_SDK_HOME_REAL"
        export WSL_SDK_MAP_HMS_FROM="$HOS_HMS_LAYOUT_DIR"
        export WSL_SDK_MAP_HMS_TO="$ORIG_DEVECO_SDK_HOME_REAL/hms"

        DEVECO_SDK_HOME_REAL="$HOS_SDK_LINK_ROOT"
        OHOS_BASE_SDK_HOME_REAL="$HOS_OHOS_LAYOUT_DIR"
    fi
fi

if [[ "$OHOS_SDK_SOURCE" == *" "* ]]; then
    if [ -n "${WSL_SDK_MAP_OHOS_FROM:-}" ] && [ -d "$OHOS_BASE_SDK_HOME_REAL" ]; then
        OHOS_SDK="$OHOS_BASE_SDK_HOME_REAL"
    else
        mkdir -p "$SDK_LINK_DIR"
        OHOS_SDK_LINK="$SDK_LINK_DIR/openharmony"
        ln -sfn "$OHOS_SDK_SOURCE" "$OHOS_SDK_LINK"
        OHOS_SDK="$OHOS_SDK_LINK"
    fi
fi

export OHOS_SDK
export OHOS_BASE_SDK_HOME="${OHOS_BASE_SDK_HOME:-$OHOS_BASE_SDK_HOME_REAL}"
export DEVECO_SDK_HOME="${DEVECO_SDK_HOME:-$DEVECO_SDK_HOME_REAL}"
export SYSROOT="$OHOS_SDK/native/sysroot"
export CMAKE_TOOLCHAIN_FILE="$OHOS_SDK/native/build/cmake/ohos.toolchain.cmake"
export HAP_SIGN_TOOL_JAR="${HAP_SIGN_TOOL_JAR:-$OHOS_SDK/toolchains/lib/hap-sign-tool.jar}"
export WAYLAND_SCANNER="${WAYLAND_SCANNER:-$HOST_TOOLS_DIR/bin/wayland-scanner}"

maybe_prepend_path "$TOOL_HOME/bin"
maybe_prepend_path "$ORIG_DEVECO_SDK_HOME_REAL/hms/toolchains/lib"
maybe_prepend_path "$ORIG_OHOS_BASE_SDK_HOME_REAL/previewer/common/bin"
WSL_EXE_EXTRA_PATHS="${WSL_EXE_EXTRA_PATHS:+$WSL_EXE_EXTRA_PATHS:}$ORIG_DEVECO_SDK_HOME_REAL/hms/toolchains/lib:$ORIG_OHOS_BASE_SDK_HOME_REAL/previewer/common/bin"
export WSL_EXE_EXTRA_PATHS

WSL_RESTOOL_PLUGIN_DIR="$SDK_LINK_DIR/restool-plugin-lib"
remove_tree "$WSL_RESTOOL_PLUGIN_DIR"
mkdir -p "$WSL_RESTOOL_PLUGIN_DIR"

for asset in "$ORIG_DEVECO_SDK_HOME_REAL/hms/toolchains/lib"/*; do
    [ -f "$asset" ] || continue
    cp -f "$asset" "$WSL_RESTOOL_PLUGIN_DIR/"
done

for asset in "$ORIG_OHOS_BASE_SDK_HOME_REAL/previewer/common/bin"/*; do
    [ -f "$asset" ] || continue
    cp -f "$asset" "$WSL_RESTOOL_PLUGIN_DIR/"
done

export WSL_RESTOOL_PLUGIN_DIR
export PATH

LLVM_BIN="$OHOS_SDK/native/llvm/bin"
CLANG_REAL="$(resolve_first_executable "${CLANG_REAL:-}" "$LLVM_BIN/clang" "$LLVM_BIN/clang.exe" || true)"
CLANGXX_REAL="$(resolve_first_executable "${CLANGXX_REAL:-}" "$LLVM_BIN/clang++" "$LLVM_BIN/clang++.exe" || true)"
LLVM_AR_REAL="$(resolve_first_executable "${LLVM_AR_REAL:-}" "$LLVM_BIN/llvm-ar" "$LLVM_BIN/llvm-ar.exe" || true)"
LLVM_STRIP_REAL="$(resolve_first_executable "${LLVM_STRIP_REAL:-}" "$LLVM_BIN/llvm-strip" "$LLVM_BIN/llvm-strip.exe" || true)"
[ -n "$CLANG_REAL" ] || env_fail "clang not found under $LLVM_BIN"
[ -n "$CLANGXX_REAL" ] || env_fail "clang++ not found under $LLVM_BIN"
[ -n "$LLVM_AR_REAL" ] || env_fail "llvm-ar not found under $LLVM_BIN"
[ -n "$LLVM_STRIP_REAL" ] || env_fail "llvm-strip not found under $LLVM_BIN"

NODE_BIN="${NODE_BIN:-$(command_or_empty node)}"
if [ -z "$NODE_BIN" ]; then
    NODE_BIN="$(resolve_first_executable \
        "$TOOL_HOME/tools/node/bin/node" \
        "$TOOL_HOME/tools/node/node" \
        "$TOOL_HOME/tools/node/node.exe" \
        || true)"
fi
[ -n "$NODE_BIN" ] || env_fail "node not found. Install nodejs in WSL or set NODE_BIN."
export NODE_BIN

if [ -z "${NODE_HOME:-}" ]; then
    case "$NODE_BIN" in
        */bin/node) NODE_HOME="$(cd "$(dirname "$NODE_BIN")/.." && pwd)" ;;
        */node.exe) NODE_HOME="$(cd "$(dirname "$NODE_BIN")" && pwd)" ;;
        *) NODE_HOME="$(cd "$(dirname "$NODE_BIN")/.." && pwd)" ;;
    esac
    export NODE_HOME
fi

JAVA_BIN="${JAVA_BIN:-$(command_or_empty java)}"
if [ -z "$JAVA_BIN" ]; then
    JAVA_BIN="$(resolve_first_executable \
        "$TOOL_HOME/jbr/bin/java" \
        "$TOOL_HOME/jbr/bin/java.exe" \
        || true)"
fi
[ -n "$JAVA_BIN" ] || env_fail "java not found. Install default-jre in WSL or set JAVA_BIN."
export JAVA_BIN

HVIGORW="${HVIGORW:-}"
if [ -z "$HVIGORW" ]; then
    HVIGORW="$(resolve_first_executable \
        "$TOOL_HOME/tools/hvigor/bin/hvigorw" \
        || true)"
fi
[ -n "$HVIGORW" ] || env_fail "hvigorw not found under $TOOL_HOME/tools/hvigor/bin"
export HVIGORW

HNPCLI_REAL="$(resolve_first_executable "${HNPCLI_REAL:-}" "$OHOS_SDK/toolchains/hnpcli" "$OHOS_SDK/toolchains/hnpcli.exe" || true)"
HDC_REAL="$(resolve_first_executable "${HDC_REAL:-}" "$OHOS_SDK/toolchains/hdc" "$OHOS_SDK/toolchains/hdc.exe" || true)"
[ -n "$HNPCLI_REAL" ] || env_fail "hnpcli not found under $OHOS_SDK/toolchains"
[ -n "$HDC_REAL" ] || env_fail "hdc not found under $OHOS_SDK/toolchains"

wrap_windows_tool() {
    local tool="$1"
    local name="$2"
    local wrapper

    if [[ "$tool" != *.exe ]] || ! command -v wslpath >/dev/null 2>&1; then
        printf '%s\n' "$tool"
        return 0
    fi

    mkdir -p "$WRAPPER_DIR"
    wrapper="$WRAPPER_DIR/$name"
    cat > "$wrapper" <<EOF
#!/bin/bash
exec '$ROOT/scripts/wsl_exe_wrapper.sh' '$tool' "\$@"
EOF
    chmod +x "$wrapper"
    printf '%s\n' "$wrapper"
}

export CLANG="$(wrap_windows_tool "$CLANG_REAL" clang)"
export CLANGXX="$(wrap_windows_tool "$CLANGXX_REAL" clangxx)"
export LLVM_AR="$(wrap_windows_tool "$LLVM_AR_REAL" llvm-ar)"
export LLVM_STRIP="$(wrap_windows_tool "$LLVM_STRIP_REAL" llvm-strip)"
export HNPCLI="$(wrap_windows_tool "$HNPCLI_REAL" hnpcli)"
export HDC="$(wrap_windows_tool "$HDC_REAL" hdc)"

PKG_CONFIG_BIN="${PKG_CONFIG_BIN:-$(command_or_empty pkg-config)}"
[ -n "$PKG_CONFIG_BIN" ] || env_fail "pkg-config not found in PATH"
export PKG_CONFIG_BIN

# Native layer ABI (HAP libs directory target)
NATIVE_ARCH="${NATIVE_ARCH:-x86_64}"

# Wine userspace target always remains x86_64.
TARGET="x86_64-linux-ohos"

case "$NATIVE_ARCH" in
    arm64-v8a)
        NATIVE_TARGET="aarch64-linux-ohos"
        NATIVE_CPU_FAMILY="aarch64"
        NATIVE_CPU="aarch64"
        ;;
    x86_64)
        NATIVE_TARGET="x86_64-linux-ohos"
        NATIVE_CPU_FAMILY="x86_64"
        NATIVE_CPU="x86_64"
        ;;
    all)
        NATIVE_TARGET=""
        NATIVE_CPU_FAMILY=""
        NATIVE_CPU=""
        ;;
    *)
        env_fail "Unsupported NATIVE_ARCH: $NATIVE_ARCH (expected arm64-v8a, x86_64 or all)"
        ;;
esac

# Device type:
# - pc: normal HarmonyOS target with execve/HNP runtime layout
# - pad: fork-only target without execve/HNP
DEVICE_TYPE="${DEVICE_TYPE:-pc}"

if [ "$DEVICE_TYPE" = "pad" ]; then
    WINE_DEVICE_ROOT="/data/storage/el2/base/files/wine"
    export PAD_CFLAGS="-DPAD_MODE"
else
    WINE_DEVICE_ROOT="/data/service/hnp/winehua.org/winehua_0.1.0/opt/winehua"
    export PAD_CFLAGS=""
fi

# Source paths
WINE_SRC="$ROOT/thirdparty/wine"
BOX64_SRC="$ROOT/thirdparty/box64"

# Output paths
SYSROOT_EXT="$BUILD_DIR/sysroot-ext"
STAGING_DIR="$ROOT/out/staging"
HNP_LAYOUT="$STAGING_DIR/opt/winehua"
OUT_DIR="$ROOT/out"

# sysroot-ext layout
SYSROOT_EXT_INC="$SYSROOT_EXT/usr/include"
SYSROOT_EXT_LIB="$SYSROOT_EXT/usr/lib/x86_64-linux-ohos"
SYSROOT_EXT_PC="$SYSROOT_EXT/usr/lib/pkgconfig"
SYSROOT_EXT_SHARE="$SYSROOT_EXT/usr/share"

# HAP project
WINEHUA="$ROOT"
NATIVE_LIBS="$WINEHUA/entry/libs/$NATIVE_ARCH"

JOBS="${JOBS:-$(nproc)}"

gen_cross_file() {
    local cross="$BUILD_DIR/ohos-x86_64-cross.txt"
    mkdir -p "$BUILD_DIR"
    cat > "$cross" <<XEOF
[binaries]
c = '$CLANG'
cpp = '$CLANGXX'
ar = '$LLVM_AR'
strip = '$LLVM_STRIP'
pkg-config = '$PKG_CONFIG_BIN'
wayland-scanner = '$WAYLAND_SCANNER'

[built-in options]
c_args = ['--target=$TARGET', '--sysroot=$SYSROOT', '-I$SYSROOT_EXT_INC']
c_link_args = ['--target=$TARGET', '--sysroot=$SYSROOT', '-fuse-ld=lld', '-L$SYSROOT_EXT_LIB']
pkg_config_path = ['$SYSROOT_EXT/usr/lib/pkgconfig', '$SYSROOT/usr/lib/pkgconfig']

[host_machine]
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
XEOF
    echo "$cross"
}

gen_cmake_toolchain() {
    local name="$1"
    local target="$2"
    local cpu="$3"
    local toolchain="$BUILD_DIR/cmake-${name}.toolchain.cmake"
    mkdir -p "$BUILD_DIR"
    cat > "$toolchain" <<XEOF
set(CMAKE_SYSTEM_NAME Linux)
set(CMAKE_SYSTEM_PROCESSOR "$cpu")
set(CMAKE_C_COMPILER "$CLANG")
set(CMAKE_CXX_COMPILER "$CLANGXX")
set(CMAKE_AR "$LLVM_AR")
set(CMAKE_STRIP "$LLVM_STRIP")
set(CMAKE_SYSROOT "$SYSROOT")
set(CMAKE_C_COMPILER_TARGET "$target")
set(CMAKE_CXX_COMPILER_TARGET "$target")
set(CMAKE_ASM_COMPILER_TARGET "$target")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_POSITION_INDEPENDENT_CODE TRUE)
set(CMAKE_C_FLAGS_INIT "-D__MUSL__")
set(CMAKE_CXX_FLAGS_INIT "-D__MUSL__")
set(CMAKE_SHARED_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_MODULE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_EXE_LINKER_FLAGS_INIT "-fuse-ld=lld")
set(CMAKE_FIND_ROOT_PATH "$SYSROOT")
set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)
XEOF
    echo "$toolchain"
}

meson_build() {
    local build="$1" src="$2"
    shift 2
    local cross
    cross="$(gen_cross_file)"
    find "$src" -type f -exec touch {} + 2>/dev/null || true
    mkdir -p "$build"
    meson setup "$build" "$src" --cross-file "$cross" "$@"
}

log()  { echo -e "\033[32m[BUILD]\033[0m $*"; }
warn() { echo -e "\033[33m[WARN]\033[0m $*"; }
err()  { echo -e "\033[31m[ERROR]\033[0m $*"; exit 1; }
