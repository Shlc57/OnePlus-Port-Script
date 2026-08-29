#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
# shellcheck source=../../tools/toolchain.sh
# shellcheck disable=SC1091 # 仓库根目录由补丁目录运行时定位。
source "$port_dir/tools/toolchain.sh"
toolchain_resolve_ndk
ndk_root="$PORT_TOOL_NDK"
android_api="${DISPLAYFEATURE_ANDROID_API:-35}"
compiler="$ndk_root/toolchains/llvm/prebuilt/linux-x86_64/bin/aarch64-linux-android${android_api}-clang++"
output_dir="$script_dir/prebuilt/odm/lib64/hw"
source_file="$script_dir/src/displayfeature_bridge.cpp"
hardware_compat_header="$script_dir/include/hardware_compat.h"
platform_binder_compat_header="$script_dir/include/platform_binder_compat.h"
output_file="$output_dir/displayfeature.default.so"
input_stamp_file="$output_file.inputs.sha256"
default_project_root="$(cd -- "$script_dir/../../.." && pwd -P)"
project_root="${DISPLAYFEATURE_PROJECT_ROOT:-$default_project_root}"

if [[ ! -d "$project_root" ]]; then
	printf '目标移植工程根目录不存在：%s\n' "$project_root" >&2
	exit 1
fi
project_root="$(cd -- "$project_root" && pwd -P)"
vendor_lib_dir="$project_root/vendor/lib64"
system_lib_dir="$project_root/system/system/lib64"

calculate_bridge_input_hash() {
	sha256sum \
		"$script_dir/build.sh" \
		"$source_file" \
		"$hardware_compat_header" \
		"$platform_binder_compat_header" | \
		awk '{print $1}' | sha256sum | awk '{print $1}'
}

if [[ ! -x "$compiler" ]]; then
	printf '未找到 Android NDK 编译器：%s\n' "$compiler" >&2
	exit 1
fi
for platform_library in libbinder.so libutils.so libsdm-disp-vndapis.so; do
	if [[ ! -f "$vendor_lib_dir/$platform_library" ]]; then
		printf '缺少目标平台库：%s\n' "$vendor_lib_dir/$platform_library" >&2
		exit 1
	fi
done
if [[ ! -f "$system_lib_dir/libbinder_ndk.so" ]]; then
	printf '缺少目标平台库：%s\n' "$system_lib_dir/libbinder_ndk.so" >&2
	exit 1
fi

mkdir -p -- "$output_dir"
temporary_output="$(mktemp "$output_dir/displayfeature.default.so.tmp.XXXXXX")"
temporary_input_stamp=""
trap 'rm -f -- "$temporary_output" "$temporary_input_stamp"' EXIT
temporary_input_stamp="$(mktemp "$output_dir/displayfeature.default.so.inputs.sha256.tmp.XXXXXX")"

"$compiler" \
	-std=c++17 \
	-Os \
	-Wall \
	-Wextra \
	-Werror \
	-fPIC \
	-fvisibility=hidden \
	-fno-exceptions \
	-fno-rtti \
	-fno-threadsafe-statics \
	-ffunction-sections \
	-fdata-sections \
	-mbranch-protection=standard \
	-nostdlib++ \
	-I"$script_dir/include" \
	-shared \
	-Wl,--as-needed \
	-Wl,--gc-sections \
	-Wl,--no-undefined \
	-Wl,--strip-all \
	-Wl,-z,max-page-size=16384 \
	-Wl,-z,relro \
	-Wl,-z,now \
	-Wl,-soname,displayfeature.default.so \
	"$source_file" \
	-llog \
	-ldl \
	"$vendor_lib_dir/libbinder.so" \
	"$system_lib_dir/libbinder_ndk.so" \
	"$vendor_lib_dir/libutils.so" \
	"$vendor_lib_dir/libsdm-disp-vndapis.so" \
	-o "$temporary_output"

bridge_input_hash="$(calculate_bridge_input_hash)"
printf '%s\n' "$bridge_input_hash" > "$temporary_input_stamp"
chmod 0644 "$temporary_output"
chmod 0644 "$temporary_input_stamp"
mv -f -- "$temporary_output" "$output_file"
mv -f -- "$temporary_input_stamp" "$input_stamp_file"
trap - EXIT
printf '已生成：%s\n' "$output_file"
printf '输入哈希：%s\n' "$bridge_input_hash"
