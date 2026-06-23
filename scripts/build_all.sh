#!/bin/bash
# build_all.sh 鈥?鍏ㄩ噺鏋勫缓: Box64 鈫?Wine 鈫?缁勮 鈫?HNP 鈫?HAP 鈫?閮ㄧ讲
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR/.."

case "${1:-}" in
    box64)  bash scripts/build_box64.sh ;;
    wine)   bash scripts/build_wine.sh ;;
    deps)   bash scripts/build_deps.sh ;;
    native) bash scripts/build_arm64_native.sh ;;
    full)
        bash scripts/build_box64.sh
        bash scripts/build_wine.sh
        ;;
    *)
        bash scripts/build_box64.sh
        ;;
esac

bash scripts/assemble.sh
bash scripts/package.sh hnp
bash scripts/package.sh hap
bash scripts/package.sh deploy
