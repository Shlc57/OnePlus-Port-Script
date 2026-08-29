#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port_dir="$(cd -- "$script_dir/../.." && pwd -P)"
# shellcheck source=../../tools/toolchain.sh
# shellcheck disable=SC1091 # 仓库根目录由补丁目录运行时定位。
source "$port_dir/tools/toolchain.sh"
kmi="${KMI:-}"

if [[ -z "$kmi" || "$kmi" == "." || "$kmi" == ".." ||
	! "$kmi" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	echo "KMI must be a plain DDK target name" >&2
	exit 1
fi
if ! toolchain_resolve_ddk; then
	echo "ddk is required; set ddk=/absolute/path/to/ddk in local.properties" >&2
	exit 1
fi

prebuilt_dir="$script_dir/prebuilt/$kmi"
mkdir -p -- "$prebuilt_dir"
build_dir="$(mktemp -d "${TMPDIR:-/tmp}/millet-core-build.XXXXXX")"
cleanup() {
	rm -rf -- "$build_dir"
}
trap cleanup EXIT
cp -a -- "$script_dir/Makefile" "$script_dir/Kbuild" "$script_dir/src" "$build_dir/"
(
	cd -- "$build_dir"
	"$PORT_TOOL_DDK" build --target "$kmi" -- DDK_TARGET="$kmi"
)

if [[ ! -f "$build_dir/millet_core.ko" || -L "$build_dir/millet_core.ko" ]]; then
	echo "DDK did not produce millet_core.ko" >&2
	exit 1
fi
install -m 0644 -- "$build_dir/millet_core.ko" "$prebuilt_dir/millet_core.ko"
echo "prebuilt/$kmi/millet_core.ko"
