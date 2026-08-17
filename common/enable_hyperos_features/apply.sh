#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"
# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
resolved_project_dir="$project_dir"

std_print "补充 HyperOS 模糊、画质、相册 HDR、游戏与声效特性属性"
std_print "注意：本补丁仅补充功能开关，不提供缺失的硬件驱动、媒体算法或音频实现"
std_print

for part_name in product vendor; do
	check_part_exists "$part_name"
done

product_target="$resolved_project_dir/product/etc/build.prop"
vendor_target="$resolved_project_dir/vendor/build.prop"
product_patch="$patcher_dir/config/product.prop"
vendor_patch="$patcher_dir/config/vendor.prop"

for required_file in \
	"$product_target" \
	"$vendor_target" \
	"$product_patch" \
	"$vendor_patch"; do
	check_file_exists "$required_file"
done
validate_prop_file "$product_patch"
validate_prop_file "$vendor_patch"
for target_file in "$product_target" "$vendor_target"; do
	if [[ -L "$target_file" ]]; then
		err_print "不支持直接修改符号链接：$target_file"
		exit 1
	fi
done

merge_prop_file "$product_patch" "$product_target"
std_print "✅ 32 项通用特性属性已写入：${product_target#"$resolved_project_dir"/}"

merge_prop_file "$vendor_patch" "$vendor_target"
std_print "✅ Gallery XDR 2.0 能力属性已写入：${vendor_target#"$resolved_project_dir"/}"

std_print "处理完成"
