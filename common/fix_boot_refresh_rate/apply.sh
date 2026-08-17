#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复开机卡顿与锁 60Hz"
std_print "来源：小米原包 mi_odm、mi_vendor；目标：底包 odm、vendor"
std_print "范围：仅合并显示、刷新率与触控属性，保留底包音频链和完整 ODM 文件树"
std_print

for part_name in mi_odm mi_vendor odm vendor; do
	check_part_exists "$part_name"
done

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
mi_odm_build_prop="$project_dir/mi_odm/etc/build.prop"
mi_vendor_build_prop="$project_dir/mi_vendor/build.prop"
odm_build_prop="$project_dir/odm/etc/build.prop"
vendor_build_prop="$project_dir/vendor/build.prop"
mi_odm_prop_list="$patcher_dir/config/mi_odm_props.list"
mi_vendor_prop_list="$patcher_dir/config/mi_vendor_props.list"

for required_file in \
	"$mi_odm_build_prop" \
	"$mi_vendor_build_prop" \
	"$odm_build_prop" \
	"$vendor_build_prop" \
	"$mi_odm_prop_list" \
	"$mi_vendor_prop_list"; do
	check_file_exists "$required_file"
done

for target_file in "$odm_build_prop" "$vendor_build_prop"; do
	if [[ -L "$target_file" ]]; then
		err_print "不支持直接修改符号链接：$target_file"
		exit 1
	fi
done

declare -a temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

build_prop_patch() {
	local source_file="${1:-}"
	local prop_list="${2:-}"
	local output_file="${3:-}"
	local source_name="${4:-原包}"
	local raw_line
	local prop_key
	local prop_value
	local prop_count=0
	local -A seen_keys=()

	: > "$output_file"
	while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
		raw_line="${raw_line%$'\r'}"
		prop_key="${raw_line#"${raw_line%%[![:space:]]*}"}"
		prop_key="${prop_key%"${prop_key##*[![:space:]]}"}"
		if [[ -z "$prop_key" || "$prop_key" == \#* ]]; then
			continue
		fi
		if [[ ! "$prop_key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
			err_print "属性清单存在无效属性名：$prop_list：$prop_key"
			return 1
		fi
		if [[ -n "${seen_keys[$prop_key]:-}" ]]; then
			err_print "属性清单存在重复属性：$prop_list：$prop_key"
			return 1
		fi
		seen_keys["$prop_key"]=1
		prop_value="$(read_prop_value "$prop_key" "$source_file")"
		if [[ -z "$prop_value" ]]; then
			err_print "$source_name 属性值不能为空：$prop_key"
			return 1
		fi
		printf '%s=%s\n' "$prop_key" "$prop_value" >> "$output_file"
		((prop_count += 1))
	done < "$prop_list"

	if (( prop_count == 0 )); then
		err_print "属性清单没有有效属性：$prop_list"
		return 1
	fi
}

odm_prop_patch="$(mktemp "$(get_config_path '.fix_boot_refresh_rate_odm.XXXXXX')")"
temporary_files+=("$odm_prop_patch")
vendor_prop_patch="$(mktemp "$(get_config_path '.fix_boot_refresh_rate_vendor.XXXXXX')")"
temporary_files+=("$vendor_prop_patch")

# 先完整读取并校验两份原包属性，避免来源不完整时只修改一部分目标文件。
build_prop_patch "$mi_odm_build_prop" "$mi_odm_prop_list" "$odm_prop_patch" "mi_odm"
build_prop_patch "$mi_vendor_build_prop" "$mi_vendor_prop_list" "$vendor_prop_patch" "mi_vendor"

# 这两个开关来自教程的刷新率修复本身，当前原包和底包均未定义。
printf '%s\n' \
	'ro.surface_flinger.enable_frame_rate_override=false' \
	'debug.sf.set_idle_timer_ms=1100' >> "$odm_prop_patch"

validate_prop_file "$odm_prop_patch"
validate_prop_file "$vendor_prop_patch"

merge_prop_file "$odm_prop_patch" "$odm_build_prop"
std_print "✅ 原包 ODM 的显示、刷新率与触控属性已合并到 odm/etc/build.prop"

merge_prop_file "$vendor_prop_patch" "$vendor_build_prop"
std_print "✅ 原包 vendor 的显示属性已合并到 vendor/build.prop"
std_print "处理完成"
