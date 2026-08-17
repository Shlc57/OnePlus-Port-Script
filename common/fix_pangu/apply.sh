#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "合并 product/pangu/system 到 system 分区"
std_print

source_tree="$project_dir/product/pangu/system"
if [[ ! -d "$source_tree" ]]; then
	skip_print "product/pangu/system 不存在，可能已完成合并"
	exit 0
fi

check_part_exists system
check_part_exists product

product_contexts="$(get_part_contexts_path product)"
system_contexts="$(get_part_contexts_path system)"
product_fsconfig="$(get_part_fsconfig_path product)"
system_fsconfig="$(get_part_fsconfig_path system)"
check_file_exists "$product_contexts"
check_file_exists "$system_contexts"
check_file_exists "$product_fsconfig"
check_file_exists "$system_fsconfig"

validate_translated_contexts_prefix \
	"$product_contexts" \
	/product/pangu/system \
	/system/system
validate_translated_fsconfig_prefix \
	"$product_fsconfig" \
	product/pangu/system \
	system/system

merge_tree "$source_tree" "$project_dir/system/system"
std_print "✅ 文件合并完成"

merge_translated_contexts_prefix \
	"$product_contexts" \
	"$system_contexts" \
	/product/pangu/system \
	/system/system
merge_translated_fsconfig_prefix \
	"$product_fsconfig" \
	"$system_fsconfig" \
	product/pangu/system \
	system/system
remove_contexts_prefix "$product_contexts" /product/pangu/system
remove_fsconfig_prefix "$product_fsconfig" product/pangu/system
std_print "✅ contexts 与 fsconfig 已转换并从 product 源路径移除"

remove_path_if_exists "$source_tree"
std_print "处理完成"
