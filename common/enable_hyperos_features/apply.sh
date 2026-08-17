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

product_target="$resolved_project_dir/product/etc/build.prop"
vendor_target="$resolved_project_dir/vendor/build.prop"
product_patch="$patcher_dir/config/product.prop"
vendor_patch="$patcher_dir/config/vendor.prop"

product_ready=1
vendor_ready=1
if [[ -L "$product_patch" ]]; then
	err_print "属性补丁不能是符号链接：$product_patch"
	exit 1
elif [[ ! -e "$product_patch" ]]; then
	warn_print "属性补丁不存在，跳过 product 属性：${product_patch#"$port_dir"/}"
	product_ready=0
elif [[ ! -f "$product_patch" ]]; then
	err_print "属性补丁不是普通文件：$product_patch"
	exit 1
fi
if [[ -L "$product_target" ]]; then
	err_print "不支持直接修改符号链接：$product_target"
	exit 1
elif [[ ! -e "$product_target" ]]; then
	warn_print "属性目标不存在，跳过 product 属性：${product_target#"$resolved_project_dir"/}"
	product_ready=0
elif [[ ! -f "$product_target" ]]; then
	err_print "属性目标不是普通文件：$product_target"
	exit 1
fi
if [[ -L "$vendor_patch" ]]; then
	err_print "属性补丁不能是符号链接：$vendor_patch"
	exit 1
elif [[ ! -e "$vendor_patch" ]]; then
	warn_print "属性补丁不存在，跳过 vendor 属性：${vendor_patch#"$port_dir"/}"
	vendor_ready=0
elif [[ ! -f "$vendor_patch" ]]; then
	err_print "属性补丁不是普通文件：$vendor_patch"
	exit 1
fi
if [[ -L "$vendor_target" ]]; then
	err_print "不支持直接修改符号链接：$vendor_target"
	exit 1
elif [[ ! -e "$vendor_target" ]]; then
	warn_print "属性目标不存在，跳过 vendor 属性：${vendor_target#"$resolved_project_dir"/}"
	vendor_ready=0
elif [[ ! -f "$vendor_target" ]]; then
	err_print "属性目标不是普通文件：$vendor_target"
	exit 1
fi

if [[ -f "$product_patch" ]]; then
	validate_prop_file "$product_patch"
fi
if [[ -f "$vendor_patch" ]]; then
	validate_prop_file "$vendor_patch"
fi

if (( product_ready == 1 )); then
	merge_prop_file "$product_patch" "$product_target"
	std_print "✅ 32 项通用特性属性已写入：${product_target#"$resolved_project_dir"/}"
fi

if (( vendor_ready == 1 )); then
	merge_prop_file "$vendor_patch" "$vendor_target"
	std_print "✅ Gallery XDR 2.0 能力属性已写入：${vendor_target#"$resolved_project_dir"/}"
fi

std_print "处理完成"
