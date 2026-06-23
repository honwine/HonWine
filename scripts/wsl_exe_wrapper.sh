#!/bin/bash
set -euo pipefail

tool="$1"
shift

temp_files=()

cleanup() {
    if [ "${#temp_files[@]}" -gt 0 ]; then
        rm -rf "${temp_files[@]}" 2>/dev/null || true
    fi
}

trap cleanup EXIT

path_exists_or_parent_exists() {
    local value="$1"
    [[ "$value" == /* ]] && { [ -e "$value" ] || [ -e "$(dirname "$value")" ]; }
}

rewrite_sdk_overlay_path() {
    local value="$1"
    local mapped="$value"
    local dll_candidate=""
    local restool_plugin_basename=""

    if [ -n "${WSL_RESTOOL_PLUGIN_DIR:-}" ]; then
        restool_plugin_basename="$(basename "$mapped")"
        case "$restool_plugin_basename" in
            libimage_transcoder_shared.so|libimage_transcoder_shared.dylib|libimage_transcoder_shared.dll)
                mapped="$WSL_RESTOOL_PLUGIN_DIR/libimage_transcoder_shared.dll"
                ;;
        esac
    fi

    if [ -n "${WSL_SDK_MAP_HMS_FROM:-}" ] && [ -n "${WSL_SDK_MAP_HMS_TO:-}" ] && [[ "$mapped" == "$WSL_SDK_MAP_HMS_FROM/"* ]]; then
        mapped="${WSL_SDK_MAP_HMS_TO}${mapped#$WSL_SDK_MAP_HMS_FROM}"
    elif [ -n "${WSL_SDK_MAP_OHOS_FROM:-}" ] && [ -n "${WSL_SDK_MAP_OHOS_TO:-}" ] && [[ "$mapped" == "$WSL_SDK_MAP_OHOS_FROM/"* ]]; then
        mapped="${WSL_SDK_MAP_OHOS_TO}${mapped#$WSL_SDK_MAP_OHOS_FROM}"
    fi

    case "$mapped" in
        *.so)
            dll_candidate="${mapped%.so}.dll"
            [ -e "$mapped" ] || [ ! -e "$dll_candidate" ] || mapped="$dll_candidate"
            ;;
        *.dylib)
            dll_candidate="${mapped%.dylib}.dll"
            [ -e "$mapped" ] || [ ! -e "$dll_candidate" ] || mapped="$dll_candidate"
            ;;
    esac

    printf '%s\n' "$mapped"
}

convert_path() {
    local value="$1"

    if ! command -v wslpath >/dev/null 2>&1; then
        printf '%s\n' "$value"
        return 0
    fi

    value="$(rewrite_sdk_overlay_path "$value")"

    if path_exists_or_parent_exists "$value"; then
        wslpath -w "$value"
        return 0
    fi

    printf '%s\n' "$value"
}

convert_restool_file_list() {
    local value="$1"
    local tmp_dir
    local tmp_file

    if ! command -v python3 >/dev/null 2>&1; then
        convert_path "$value"
        return 0
    fi

    if ! path_exists_or_parent_exists "$value" || [ ! -f "$value" ]; then
        convert_path "$value"
        return 0
    fi

    tmp_dir="$(mktemp -d "$(dirname "$value")/.restool-config.XXXXXX")"
    tmp_file="$tmp_dir/$(basename "$value")"
    python3 - "$value" "$tmp_file" "$tmp_dir" <<'PY'
import json
import os
import subprocess
import sys

src, dst, tmp_dir = sys.argv[1], sys.argv[2], sys.argv[3]
cache = {}
counter = 0
ohos_from = os.environ.get("WSL_SDK_MAP_OHOS_FROM", "")
ohos_to = os.environ.get("WSL_SDK_MAP_OHOS_TO", "")
hms_from = os.environ.get("WSL_SDK_MAP_HMS_FROM", "")
hms_to = os.environ.get("WSL_SDK_MAP_HMS_TO", "")
restool_plugin_dir = os.environ.get("WSL_RESTOOL_PLUGIN_DIR", "")

def rewrite_sdk_overlay_path(value: str) -> str:
    mapped = value
    basename = os.path.basename(mapped)

    if restool_plugin_dir and basename in {
        "libimage_transcoder_shared.so",
        "libimage_transcoder_shared.dylib",
        "libimage_transcoder_shared.dll",
    }:
        mapped = os.path.join(restool_plugin_dir, "libimage_transcoder_shared.dll")

    if hms_from and hms_to and mapped.startswith(f"{hms_from}/"):
        mapped = f"{hms_to}{mapped[len(hms_from):]}"
    elif ohos_from and ohos_to and mapped.startswith(f"{ohos_from}/"):
        mapped = f"{ohos_to}{mapped[len(ohos_from):]}"

    if not os.path.exists(mapped):
        if mapped.endswith(".so"):
            dll_candidate = f"{mapped[:-3]}.dll"
            if os.path.exists(dll_candidate):
                mapped = dll_candidate
        elif mapped.endswith(".dylib"):
            dll_candidate = f"{mapped[:-6]}.dll"
            if os.path.exists(dll_candidate):
                mapped = dll_candidate

    return mapped

def looks_like_path(value: object) -> bool:
    if not isinstance(value, str) or not value.startswith("/"):
        return False

    resolved = rewrite_sdk_overlay_path(value)
    return (
        os.path.exists(resolved)
        or os.path.exists(os.path.dirname(resolved) or "/")
    )

def to_windows_path(value: str) -> str:
    resolved = rewrite_sdk_overlay_path(value)
    return subprocess.check_output(["wslpath", "-w", resolved], text=True).strip()

def next_temp_json_path(source_path: str) -> str:
    global counter
    counter += 1
    nested_dir = os.path.join(tmp_dir, f"nested-{counter}")
    os.makedirs(nested_dir, exist_ok=True)
    return os.path.join(nested_dir, os.path.basename(source_path))

def rewrite_json_file(source_path: str, target_path: str | None = None) -> str:
    if source_path in cache:
        return cache[source_path]

    output_path = target_path or next_temp_json_path(source_path)
    cache[source_path] = output_path

    with open(source_path, "r", encoding="utf-8") as handle:
        data = json.load(handle)

    if os.path.basename(source_path) == "opt-compression.json":
        compression = data.get("compression", {})
        media = compression.get("media", {})
        filters = compression.get("filters", [])
        if not media.get("enable") and not filters:
            context = data.get("context")
            if isinstance(context, dict):
                context.pop("extensionPath", None)

    with open(output_path, "w", encoding="utf-8") as handle:
        json.dump(convert(data), handle, ensure_ascii=False)

    return output_path

def convert(value: object):
    if isinstance(value, dict):
        return {key: convert(item) for key, item in value.items()}
    if isinstance(value, list):
        return [convert(item) for item in value]
    if looks_like_path(value):
        resolved = rewrite_sdk_overlay_path(value)
        if os.path.isfile(resolved) and os.path.splitext(resolved)[1].lower() in {".json", ".json5"}:
            return to_windows_path(rewrite_json_file(resolved))
        return to_windows_path(value)
    return value

rewrite_json_file(src, dst)
PY

    temp_files+=("$tmp_dir")
    convert_path "$tmp_file"
}

convert_response_file() {
    local value="$1"
    local source_path="${value#@}"
    local tmp_dir
    local tmp_file

    if ! command -v python3 >/dev/null 2>&1; then
        printf '@%s\n' "$(convert_path "$source_path")"
        return 0
    fi

    if ! path_exists_or_parent_exists "$source_path" || [ ! -f "$source_path" ]; then
        printf '@%s\n' "$(convert_path "$source_path")"
        return 0
    fi

    tmp_dir="$(mktemp -d "$(dirname "$source_path")/.response-file.XXXXXX")"
    tmp_file="$tmp_dir/$(basename "$source_path")"
    python3 - "$source_path" "$tmp_file" <<'PY'
import os
import re
import subprocess
import sys

src, dst = sys.argv[1], sys.argv[2]
ohos_from = os.environ.get("WSL_SDK_MAP_OHOS_FROM", "")
ohos_to = os.environ.get("WSL_SDK_MAP_OHOS_TO", "")
hms_from = os.environ.get("WSL_SDK_MAP_HMS_FROM", "")
hms_to = os.environ.get("WSL_SDK_MAP_HMS_TO", "")
restool_plugin_dir = os.environ.get("WSL_RESTOOL_PLUGIN_DIR", "")

def rewrite_sdk_overlay_path(value: str) -> str:
    mapped = value
    basename = os.path.basename(mapped)

    if restool_plugin_dir and basename in {
        "libimage_transcoder_shared.so",
        "libimage_transcoder_shared.dylib",
        "libimage_transcoder_shared.dll",
    }:
        mapped = os.path.join(restool_plugin_dir, "libimage_transcoder_shared.dll")

    if hms_from and hms_to and mapped.startswith(f"{hms_from}/"):
        mapped = f"{hms_to}{mapped[len(hms_from):]}"
    elif ohos_from and ohos_to and mapped.startswith(f"{ohos_from}/"):
        mapped = f"{ohos_to}{mapped[len(ohos_from):]}"

    if not os.path.exists(mapped):
        if mapped.endswith(".so"):
            dll_candidate = f"{mapped[:-3]}.dll"
            if os.path.exists(dll_candidate):
                mapped = dll_candidate
        elif mapped.endswith(".dylib"):
            dll_candidate = f"{mapped[:-6]}.dll"
            if os.path.exists(dll_candidate):
                mapped = dll_candidate

    return mapped

def looks_like_path(value: str) -> bool:
    if not isinstance(value, str) or not value.startswith("/") or "/" not in value[1:]:
        return False

    resolved = rewrite_sdk_overlay_path(value)
    return os.path.exists(resolved) or os.path.exists(os.path.dirname(resolved) or "/")

def to_windows_path(value: str) -> str:
    resolved = rewrite_sdk_overlay_path(value)
    return subprocess.check_output(["wslpath", "-w", resolved], text=True).strip()

pattern = re.compile(r"/[^;\s\r\n\"']+")
text = open(src, "r", encoding="utf-8").read()

def replace(match: re.Match[str]) -> str:
    token = match.group(0)
    if looks_like_path(token):
        return to_windows_path(token)
    return token

with open(dst, "w", encoding="utf-8") as handle:
    handle.write(pattern.sub(replace, text))
PY

    temp_files+=("$tmp_dir")
    printf '@%s\n' "$(convert_path "$tmp_file")"
}

build_windows_path_env() {
    local current_windows_path=""
    local extra_windows_path=""
    local item=""
    local resolved=""
    local converted=""
    local old_ifs="$IFS"

    if command -v cmd.exe >/dev/null 2>&1; then
        current_windows_path="$(cmd.exe /c echo %PATH% 2>/dev/null | tr -d '\r' | tail -n 1)"
    fi

    if [ -n "${WSL_EXE_EXTRA_PATHS:-}" ] && command -v wslpath >/dev/null 2>&1; then
        IFS=':'
        for item in $WSL_EXE_EXTRA_PATHS; do
            [ -n "$item" ] || continue
            resolved="$(rewrite_sdk_overlay_path "$item")"
            [ -d "$resolved" ] || continue
            converted="$(wslpath -w "$resolved")"
            if [ -z "$extra_windows_path" ]; then
                extra_windows_path="$converted"
            else
                extra_windows_path="$extra_windows_path;$converted"
            fi
        done
        IFS="$old_ifs"
    fi

    if [ -n "$extra_windows_path" ]; then
        if [ -n "$current_windows_path" ]; then
            printf '%s;%s\n' "$extra_windows_path" "$current_windows_path"
        else
            printf '%s\n' "$extra_windows_path"
        fi
        return 0
    fi

    printf '%s\n' "$current_windows_path"
}

converted=()
expect_path=0
expect_restool_file_list=0

for arg in "$@"; do
    if [ "$expect_restool_file_list" -eq 1 ]; then
        converted+=("$(convert_restool_file_list "$arg")")
        expect_restool_file_list=0
        continue
    fi

    if [ "$expect_path" -eq 1 ]; then
        converted+=("$(convert_path "$arg")")
        expect_path=0
        continue
    fi

    case "$arg" in
        -l|--fileList)
            converted+=("$arg")
            expect_restool_file_list=1
            ;;
        -I|-L|-B|-isystem|-isysroot|-o|-MF|-include|-imacros|-resource-dir|-T|--sysroot|--gcc-toolchain)
            converted+=("$arg")
            expect_path=1
            ;;
        --fileList=*)
            converted+=("${arg%%=*}=$(convert_restool_file_list "${arg#*=}")")
            ;;
        --sysroot=*|--gcc-toolchain=*|--config=*|--resource-dir=*|--version-script=*)
            converted+=("${arg%%=*}=$(convert_path "${arg#*=}")")
            ;;
        -I/*|-L/*|-B/*)
            converted+=("${arg:0:2}$(convert_path "${arg:2}")")
            ;;
        -isystem/*)
            converted+=("-isystem$(convert_path "${arg:8}")")
            ;;
        -isysroot/*)
            converted+=("-isysroot$(convert_path "${arg:9}")")
            ;;
        -o/*)
            converted+=("-o$(convert_path "${arg:2}")")
            ;;
        -MF/*)
            converted+=("-MF$(convert_path "${arg:3}")")
            ;;
        -include/*)
            converted+=("-include$(convert_path "${arg:8}")")
            ;;
        -imacros/*)
            converted+=("-imacros$(convert_path "${arg:9}")")
            ;;
        -resource-dir/*)
            converted+=("-resource-dir$(convert_path "${arg:13}")")
            ;;
        -T/*)
            converted+=("-T$(convert_path "${arg:2}")")
            ;;
        @/*)
            converted+=("$(convert_response_file "$arg")")
            ;;
        /*)
            converted+=("$(convert_path "$arg")")
            ;;
        *)
            converted+=("$arg")
            ;;
    esac
done

if [[ "$tool" == *.exe ]]; then
    windows_path_env="$(build_windows_path_env)"
    if [ -n "$windows_path_env" ]; then
        export PATH="$windows_path_env"
    fi
fi

"$tool" "${converted[@]}"
