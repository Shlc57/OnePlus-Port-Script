#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "补充 NFC 功能属性"
std_print "来源：小米原包 mi_odm；目标：底包 odm"
std_print

for part_name in mi_odm odm; do
	check_part_exists "$part_name"
done

source_file="$project_dir/mi_odm/etc/build.prop"
target_file="$project_dir/odm/etc/build.prop"
prop_list="$patcher_dir/config/mi_odm_props.list"
check_file_exists "$source_file"
check_file_exists "$target_file"
check_file_exists "$prop_list"
if [[ -L "$target_file" ]]; then
	err_print "不支持直接修改符号链接：$target_file"
	exit 1
fi

prop_patch="$(mktemp "$(get_config_path '.fix_nfc.XXXXXX')")"
cleanup() {
	rm -f -- "$prop_patch"
}
trap cleanup EXIT

declare -A seen_keys=()
prop_count=0
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
	raw_line="${raw_line%$'\r'}"
	prop_key="${raw_line#"${raw_line%%[![:space:]]*}"}"
	prop_key="${prop_key%"${prop_key##*[![:space:]]}"}"
	[[ -z "$prop_key" || "$prop_key" == \#* ]] && continue
	if [[ ! "$prop_key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
		err_print "属性清单存在无效属性名：$prop_list：$prop_key"
		exit 1
	fi
	if [[ -n "${seen_keys[$prop_key]:-}" ]]; then
		err_print "属性清单存在重复属性：$prop_list：$prop_key"
		exit 1
	fi
	seen_keys["$prop_key"]=1
	prop_value="$(read_prop_value "$prop_key" "$source_file")"
	if [[ -z "$prop_value" ]]; then
		err_print "mi_odm 属性值不能为空：$prop_key"
		exit 1
	fi
	printf '%s=%s\n' "$prop_key" "$prop_value" >> "$prop_patch"
	((prop_count += 1))
done < "$prop_list"

if (( prop_count == 0 )); then
	err_print "属性清单没有有效属性：$prop_list"
	exit 1
fi

validate_prop_file "$prop_patch"
merge_prop_file "$prop_patch" "$target_file"
std_print "✅ 已从 mi_odm 动态提取并写入 $prop_count 项 NFC 属性：${target_file#"$project_dir"/}"

std_print "处理完成"
