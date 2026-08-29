#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "禁用小米 8 Elite 的 Vulkan 特性（不禁用可能卡在首屏）"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
prop_file="$project_dir/product/etc/build.prop"
prop_key="persist.sys.enhance_vkpipelinecache.enable"
if [[ -L "$prop_file" ]]; then
	err_print "不支持直接修改符号链接：$prop_file"
	exit 1
elif [[ ! -e "$prop_file" ]]; then
	warn_print "属性目标不存在，跳过：product/etc/build.prop"
	exit 0
elif [[ ! -f "$prop_file" ]]; then
	err_print "属性目标不是普通文件：$prop_file"
	exit 1
fi

if grep -Eq '^[[:space:]]*persist\.sys\.enhance_vkpipelinecache\.enable[[:space:]]*=' "$prop_file"; then
	comment_prop "$prop_file" "$prop_key"
	std_print "处理完成"
elif grep -Eq '^[[:space:]]*#[[:space:]]*persist\.sys\.enhance_vkpipelinecache\.enable[[:space:]]*=' "$prop_file"; then
	skip_print "$prop_key 已禁用"
else
	warn_print "属性不存在，跳过：product/etc/build.prop 中的 $prop_key"
fi
