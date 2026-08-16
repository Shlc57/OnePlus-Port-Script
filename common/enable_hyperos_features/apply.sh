#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"
# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
resolved_project_dir="$project_dir"

std_print "补充 HyperOS 模糊、画质、游戏与声效特性属性"
std_print "注意：本补丁仅补充功能开关，不提供缺失的硬件驱动、媒体算法或音频实现"
std_print

check_part_exists product

target_file="$resolved_project_dir/product/etc/build.prop"
prop_patch="$patcher_dir/config/product.prop"
check_file_exists "$target_file"
check_file_exists "$prop_patch"
validate_prop_file "$prop_patch"
if [[ -L "$target_file" ]]; then
	err_print "不支持直接修改符号链接：$target_file"
	exit 1
fi

merge_prop_file "$prop_patch" "$target_file"
std_print "✅ 32 项特性属性已写入：${target_file#"$resolved_project_dir"/}"

std_print "处理完成"
