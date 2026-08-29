#!/usr/bin/env bash
set -Eeuo pipefail

# Build-time JAR patcher for the OnePlus ADFR RUS loader.  It also removes the
# exact Full-AOD init replay emitted by the superseded revision.
patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port_dir="$(cd -- "$patcher_dir/../.." && pwd -P)"
# shellcheck source=../../tools/toolchain.sh
# shellcheck disable=SC1091 # 仓库根目录由补丁目录运行时定位。
source "$port_dir/tools/toolchain.sh"
toolchain_resolve_apktool
apktool_args=()
for apktool_argument in "${PORT_TOOL_APKTOOL_COMMAND[@]}"; do
	# 以 --option=value 形式传递，避免 JAR 模式的 -jar 被 argparse 当作选项。
	apktool_args+=("--apktool-command=$apktool_argument")
done
exec python3 "$patcher_dir/patch_miui_services_adfr.py" "${apktool_args[@]}" "$@"
