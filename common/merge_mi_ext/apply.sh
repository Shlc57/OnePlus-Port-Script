#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "合并 mi_ext 分区"
std_print "来源：原包 mi_ext；目标：真实 product、system_ext、system 分区路径"
std_print

declare -a temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

# mi_ext 合并后不再是独立属性源和 product 挂载点，需补齐运行时兼容入口。
ensure_mi_ext_runtime_compat() {
	# project_dir 由 tools.sh 的 init_port_env 设置。
	# shellcheck disable=SC2154
	local mi_ext_build_prop="$project_dir/system/mi_ext/etc/build.prop"
	local product_build_prop="$project_dir/product/etc/build.prop"
	local system_fsconfig
	local system_contexts
	local compat_link="$project_dir/system/mi_ext/product"
	local cust_feature_key="ro.mi.os.custfeatureresolve"
	local cust_feature_value
	local contexts_entry
	local prop_update_ready=1

	system_fsconfig="$(get_part_fsconfig_path system)"
	system_contexts="$(get_part_contexts_path system)"
	check_file_exists "$system_fsconfig"
	check_file_exists "$system_contexts"
	check_partition_metadata_tool >/dev/null

	if [[ -L "$mi_ext_build_prop" ]]; then
		err_print "不支持从符号链接读取属性：$mi_ext_build_prop"
		return 1
	elif [[ ! -e "$mi_ext_build_prop" ]]; then
		warn_print "CustFeatureResolve 属性来源不存在，跳过属性迁移：${mi_ext_build_prop#"$project_dir"/}"
		prop_update_ready=0
	elif [[ ! -f "$mi_ext_build_prop" ]]; then
		err_print "CustFeatureResolve 属性来源不是普通文件：$mi_ext_build_prop"
		return 1
	fi
	if [[ -L "$product_build_prop" ]]; then
		err_print "不支持直接修改符号链接：$product_build_prop"
		return 1
	elif [[ ! -e "$product_build_prop" ]]; then
		warn_print "CustFeatureResolve 属性目标不存在，跳过属性迁移：${product_build_prop#"$project_dir"/}"
		prop_update_ready=0
	elif [[ ! -f "$product_build_prop" ]]; then
		err_print "CustFeatureResolve 属性目标不是普通文件：$product_build_prop"
		return 1
	fi
	if (( prop_update_ready == 1 )); then
		if grep -Eq "^[[:space:]]*${cust_feature_key//./\\.}[[:space:]]*=" "$mi_ext_build_prop"; then
			cust_feature_value="$(read_prop_value "$cust_feature_key" "$mi_ext_build_prop")"
			if [[ -z "$cust_feature_value" ]]; then
				warn_print "CustFeatureResolve 属性值为空，跳过属性迁移：$cust_feature_key"
				prop_update_ready=0
			fi
		else
			warn_print "CustFeatureResolve 属性不存在，跳过属性迁移：$cust_feature_key"
			prop_update_ready=0
		fi
	fi
	if [[ -L "$compat_link" ]]; then
		if [[ "$(readlink -- "$compat_link")" != "/product" ]]; then
			err_print "mi_ext product 兼容链接目标错误：$compat_link"
			return 1
		fi
	elif [[ -e "$compat_link" ]]; then
		err_print "mi_ext product 兼容路径已存在且不是符号链接：$compat_link"
		return 1
	fi

	if (( prop_update_ready == 1 )); then
		ensure_prop "$product_build_prop" "$cust_feature_key" "$cust_feature_value"
		std_print "✅ CustFeatureResolve 启用属性已迁移到 product"
	fi

	if [[ ! -L "$compat_link" ]]; then
		mkdir -p -- "$(dirname -- "$compat_link")"
		ln -s -- /product "$compat_link"
	fi
	std_print "✅ 已建立 /mi_ext/product -> /product 兼容路径"

	ensure_part_fsconfig_entry system mi_ext/product 0 0 0644

	contexts_entry="$(mktemp "$(get_config_path '.mi_ext_product_contexts.XXXXXX')")"
	temporary_files+=("$contexts_entry")
	printf '%s\n' '/system/mi_ext/product u:object_r:system_file:s0' > "$contexts_entry"
	merge_contexts_file "$contexts_entry" "$system_contexts"
	std_print "✅ mi_ext product 兼容路径元数据已同步"
}

source_part="$project_dir/mi_ext"
if [[ ! -d "$source_part" ]]; then
	if [[ -f "$project_dir/system/mi_ext/etc/build.prop" ]]; then
		skip_print "mi_ext 分区不存在，按已完成合并的工作树补齐运行时兼容"
		ensure_mi_ext_runtime_compat
	else
		skip_print "mi_ext 分区不存在"
	fi
	exit 0
fi

for part_name in product system_ext system; do
	check_part_exists "$part_name"
	check_file_exists "$(get_part_contexts_path "$part_name")"
	check_file_exists "$(get_part_fsconfig_path "$part_name")"
done

mi_ext_contexts="$(get_part_contexts_path mi_ext)"
mi_ext_fsconfig="$(get_part_fsconfig_path mi_ext)"
check_file_exists "$mi_ext_contexts"
check_file_exists "$mi_ext_fsconfig"

for source_name in product system_ext system etc; do
	if [[ ! -d "$source_part/$source_name" ]]; then
		err_print "mi_ext 缺少目录：$source_name"
		exit 1
	fi
done

validate_translated_contexts_prefix "$mi_ext_contexts" /mi_ext/product /product
validate_translated_contexts_prefix "$mi_ext_contexts" /mi_ext/system_ext /system_ext
validate_translated_contexts_prefix "$mi_ext_contexts" /mi_ext/system /system/system
validate_translated_contexts_prefix "$mi_ext_contexts" /mi_ext/etc /system/mi_ext/etc
validate_translated_fsconfig_prefix "$mi_ext_fsconfig" mi_ext/product product
validate_translated_fsconfig_prefix "$mi_ext_fsconfig" mi_ext/system_ext system_ext
validate_translated_fsconfig_prefix "$mi_ext_fsconfig" mi_ext/system system/system
validate_translated_fsconfig_prefix "$mi_ext_fsconfig" mi_ext/etc system/mi_ext/etc

product_build_prop="$project_dir/product/etc/build.prop"

merge_tree "$source_part/product" "$project_dir/product"
std_print "✅ product 文件合并完成"
merge_tree "$source_part/system_ext" "$project_dir/system_ext"
std_print "✅ system_ext 文件合并完成"
merge_tree "$source_part/system" "$project_dir/system/system"
std_print "✅ system 文件合并完成"
merge_tree "$source_part/etc" "$project_dir/system/mi_ext/etc"
std_print "✅ etc 文件合并完成"

merge_translated_contexts_prefix \
	"$mi_ext_contexts" "$(get_part_contexts_path product)" /mi_ext/product /product
merge_translated_contexts_prefix \
	"$mi_ext_contexts" "$(get_part_contexts_path system_ext)" /mi_ext/system_ext /system_ext
merge_translated_contexts_prefix \
	"$mi_ext_contexts" "$(get_part_contexts_path system)" /mi_ext/system /system/system
merge_translated_contexts_prefix \
	"$mi_ext_contexts" "$(get_part_contexts_path system)" /mi_ext/etc /system/mi_ext/etc
merge_translated_fsconfig_prefix \
	"$mi_ext_fsconfig" "$(get_part_fsconfig_path product)" mi_ext/product product
merge_translated_fsconfig_prefix \
	"$mi_ext_fsconfig" "$(get_part_fsconfig_path system_ext)" mi_ext/system_ext system_ext
merge_translated_fsconfig_prefix \
	"$mi_ext_fsconfig" "$(get_part_fsconfig_path system)" mi_ext/system system/system
merge_translated_fsconfig_prefix \
	"$mi_ext_fsconfig" "$(get_part_fsconfig_path system)" mi_ext/etc system/mi_ext/etc
std_print "✅ mi_ext contexts 与 fsconfig 转换完成"

mi_ext_build_prop="$project_dir/system/mi_ext/etc/build.prop"
marker_key="ro.miui.support.system.app.uninstall.v2"
if [[ -L "$mi_ext_build_prop" ]]; then
	err_print "不支持通过符号链接迁移 mi_ext 属性：$mi_ext_build_prop"
	exit 1
elif [[ ! -e "$mi_ext_build_prop" ]]; then
	warn_print "mi_ext 中没有 etc/build.prop，跳过属性迁移"
elif [[ ! -f "$mi_ext_build_prop" ]]; then
	err_print "mi_ext 属性来源不是普通文件：$mi_ext_build_prop"
	exit 1
else
	if [[ -L "$product_build_prop" ]]; then
		err_print "不支持通过符号链接迁移 mi_ext 属性：$product_build_prop"
		exit 1
	elif [[ ! -e "$product_build_prop" ]]; then
		warn_print "属性目标不存在，跳过卸载属性迁移：${product_build_prop#"$project_dir"/}"
	elif [[ ! -f "$product_build_prop" ]]; then
		err_print "mi_ext 属性目标不是普通文件：$product_build_prop"
		exit 1
	else
		mi_ext_head="$(mktemp "${mi_ext_build_prop}.head.XXXXXX")"
		temporary_files+=("$mi_ext_head")
		product_tail="$(mktemp "${product_build_prop}.mi_ext.XXXXXX")"
		temporary_files+=("$product_tail")
		if awk -v head="$mi_ext_head" -v tail="$product_tail" -v key="$marker_key" '
		function is_marker(line, candidate) {
			candidate = line
			sub(/^[[:space:]]*/, "", candidate)
			if (substr(candidate, 1, 1) == "#") {
				candidate = substr(candidate, 2)
				sub(/^[[:space:]]*/, "", candidate)
			}
			return candidate == key "=true"
		}
		{
			if (!found && is_marker($0)) {
				found = 1
				next
			}
			if (found) {
				print >> tail
			} else {
				print >> head
			}
		}
		END { exit(found ? 0 : 3) }
		' "$mi_ext_build_prop"; then
			append_unique_lines "$product_tail" "$product_build_prop"
			chmod --reference="$mi_ext_build_prop" -- "$mi_ext_head"
			replace_file_if_different "$mi_ext_head" "$mi_ext_build_prop"
			std_print "✅ 卸载属性标记后的内容已迁移到 product"
		else
			awk_status=$?
			if (( awk_status == 3 )); then
				warn_print "mi_ext build.prop 中没有卸载属性标记，跳过属性迁移"
			else
				exit "$awk_status"
			fi
		fi
	fi
fi

ensure_mi_ext_runtime_compat

remove_path_if_exists "$source_part"
std_print "处理完成"
