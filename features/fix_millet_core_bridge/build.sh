#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
kmi="${KMI:-}"

if [[ -z "$kmi" || "$kmi" == "." || "$kmi" == ".." ||
	! "$kmi" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	echo "KMI must be a plain DDK target name" >&2
	exit 1
fi
if ! command -v ddk >/dev/null 2>&1; then
	echo "ddk is required" >&2
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
	ddk build --target "$kmi" -- DDK_TARGET="$kmi"
)

if [[ ! -f "$build_dir/millet_core.ko" || -L "$build_dir/millet_core.ko" ]]; then
	echo "DDK did not produce millet_core.ko" >&2
	exit 1
fi
install -m 0644 -- "$build_dir/millet_core.ko" "$prebuilt_dir/millet_core.ko"
echo "prebuilt/$kmi/millet_core.ko"
