#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "禁用小米 8 Elite 的 Vulkan 特性（不禁用可能卡在首屏）"
std_print

check_part_exists product

prop_file="$project_dir/product/etc/build.prop"
prop_key="persist.sys.enhance_vkpipelinecache.enable"
if [[ ! -f "$prop_file" ]]; then
	skip_print "未找到 product/etc/build.prop"
	exit 0
fi

if grep -Eq '^[[:space:]]*persist\.sys\.enhance_vkpipelinecache\.enable[[:space:]]*=' "$prop_file"; then
	comment_prop "$prop_file" "$prop_key"
	std_print "处理完成"
elif grep -Eq '^[[:space:]]*#[[:space:]]*persist\.sys\.enhance_vkpipelinecache\.enable[[:space:]]*=' "$prop_file"; then
	skip_print "$prop_key 已禁用"
else
	skip_print "product/etc/build.prop 中不存在 $prop_key"
fi
