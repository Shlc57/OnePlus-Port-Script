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
check_file_exists "$product_contexts"
check_file_exists "$system_contexts"

filtered_contexts="$(mktemp "${product_contexts}.tmp.XXXXXX")"
converted_contexts="$(mktemp "${system_contexts}.pangu.XXXXXX")"
cleanup() {
	rm -f -- "$filtered_contexts" "$converted_contexts"
}
trap cleanup EXIT

awk -v converted="$converted_contexts" '
	/^\/product\/pangu\/system([[:space:]]|\/|$)/ {
		line = $0
		sub(/^\/product\/pangu\/system/, "/system/system", line)
		print line >> converted
		next
	}
	{ print }
' "$product_contexts" > "$filtered_contexts"

merge_tree "$source_tree" "$project_dir/system/system"
std_print "✅ 文件合并完成"

if [[ -s "$converted_contexts" ]]; then
	append_unique_lines "$converted_contexts" "$system_contexts"
	chmod --reference="$product_contexts" -- "$filtered_contexts"
	replace_file_if_different "$filtered_contexts" "$product_contexts"
	std_print "✅ file_contexts 转换完成"
else
	skip_print "product_contexts 中没有待转换的 pangu 条目"
fi

remove_path_if_exists "$source_tree"
std_print "处理完成"
