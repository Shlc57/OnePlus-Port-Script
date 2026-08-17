#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复开机卡顿与锁 60Hz"
std_print "来源：小米原包 mi_odm、mi_vendor；目标：底包 odm、vendor"
std_print "范围：仅合并显示、刷新率与触控属性，保留底包音频链和完整 ODM 文件树"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
mi_odm_build_prop="$project_dir/mi_odm/etc/build.prop"
mi_vendor_build_prop="$project_dir/mi_vendor/build.prop"
odm_build_prop="$project_dir/odm/etc/build.prop"
vendor_build_prop="$project_dir/vendor/build.prop"
mi_odm_prop_list="$patcher_dir/config/mi_odm_props.list"
mi_vendor_prop_list="$patcher_dir/config/mi_vendor_props.list"

odm_target_ready=1
vendor_target_ready=1
if [[ -L "$odm_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$odm_build_prop"
	exit 1
elif [[ ! -e "$odm_build_prop" ]]; then
	warn_print "属性目标不存在，跳过 ODM 刷新率属性：${odm_build_prop#"$project_dir"/}"
	odm_target_ready=0
elif [[ ! -f "$odm_build_prop" ]]; then
	err_print "属性目标不是普通文件：$odm_build_prop"
	exit 1
fi
if [[ -L "$vendor_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$vendor_build_prop"
	exit 1
elif [[ ! -e "$vendor_build_prop" ]]; then
	warn_print "属性目标不存在，跳过 vendor 显示属性：${vendor_build_prop#"$project_dir"/}"
	vendor_target_ready=0
elif [[ ! -f "$vendor_build_prop" ]]; then
	err_print "属性目标不是普通文件：$vendor_build_prop"
	exit 1
fi
if (( odm_target_ready == 0 && vendor_target_ready == 0 )); then
	std_print "处理完成"
	exit 0
fi

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
	local listed_prop_count=0
	local -A seen_keys=()

	: > "$output_file"
	if [[ -L "$source_file" ]]; then
		err_print "不支持从符号链接读取属性：$source_file"
		return 1
	elif [[ ! -e "$source_file" ]]; then
		warn_print "属性来源不存在，跳过 $source_name 动态属性：${source_file#"$project_dir"/}"
		return 0
	elif [[ ! -f "$source_file" ]]; then
		err_print "属性来源不是普通文件：$source_file"
		return 1
	fi
	if [[ -L "$prop_list" ]]; then
		err_print "属性清单不能是符号链接：$prop_list"
		return 1
	elif [[ ! -e "$prop_list" ]]; then
		warn_print "属性清单不存在，跳过 $source_name 动态属性：${prop_list#"$port_dir"/}"
		return 0
	elif [[ ! -f "$prop_list" ]]; then
		err_print "属性清单不是普通文件：$prop_list"
		return 1
	fi
	while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
		raw_line="${raw_line%$'\r'}"
		prop_key="${raw_line#"${raw_line%%[![:space:]]*}"}"
		prop_key="${prop_key%"${prop_key##*[![:space:]]}"}"
		if [[ -z "$prop_key" || "$prop_key" == \#* ]]; then
			continue
		fi
		((listed_prop_count += 1))
		if [[ ! "$prop_key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
			err_print "属性清单存在无效属性名：$prop_list：$prop_key"
			return 1
		fi
		if [[ -n "${seen_keys[$prop_key]:-}" ]]; then
			err_print "属性清单存在重复属性：$prop_list：$prop_key"
			return 1
		fi
		seen_keys["$prop_key"]=1
		if ! grep -Eq "^[[:space:]]*${prop_key//./\\.}[[:space:]]*=" "$source_file"; then
			warn_print "属性不存在，跳过：$source_name 中的 $prop_key"
			continue
		fi
		prop_value="$(read_prop_value "$prop_key" "$source_file")"
		if [[ -z "$prop_value" ]]; then
			warn_print "属性值为空，跳过：$source_name 中的 $prop_key"
			continue
		fi
		printf '%s=%s\n' "$prop_key" "$prop_value" >> "$output_file"
		((prop_count += 1))
	done < "$prop_list"

	if (( listed_prop_count == 0 )); then
		warn_print "属性清单没有有效条目，跳过：${prop_list#"$port_dir"/}"
	elif (( prop_count == 0 )); then
		warn_print "$source_name 没有可合并的动态属性，跳过"
	fi
}

odm_prop_patch="$(mktemp "$(get_config_path '.fix_boot_refresh_rate_odm.XXXXXX')")"
temporary_files+=("$odm_prop_patch")
vendor_prop_patch="$(mktemp "$(get_config_path '.fix_boot_refresh_rate_vendor.XXXXXX')")"
temporary_files+=("$vendor_prop_patch")

if (( odm_target_ready == 1 )); then
	build_prop_patch "$mi_odm_build_prop" "$mi_odm_prop_list" "$odm_prop_patch" "mi_odm"
fi
if (( vendor_target_ready == 1 )); then
	build_prop_patch "$mi_vendor_build_prop" "$mi_vendor_prop_list" "$vendor_prop_patch" "mi_vendor"
fi

# 这两个开关来自教程的刷新率修复本身，当前原包和底包均未定义。
if (( odm_target_ready == 1 )); then
	printf '%s\n' \
		'ro.surface_flinger.enable_frame_rate_override=false' \
		'debug.sf.set_idle_timer_ms=1100' >> "$odm_prop_patch"
fi

if (( odm_target_ready == 1 )); then
	validate_prop_file "$odm_prop_patch"
fi
if (( vendor_target_ready == 1 )) && [[ -s "$vendor_prop_patch" ]]; then
	validate_prop_file "$vendor_prop_patch"
fi

if (( odm_target_ready == 1 )); then
	odm_dynamic_prop_count="$(awk 'END { print NR - 2 }' "$odm_prop_patch")"
	merge_prop_file "$odm_prop_patch" "$odm_build_prop"
	std_print "✅ ODM 显示、刷新率与触控属性已合并到 odm/etc/build.prop（动态提取 $odm_dynamic_prop_count 项，固定补充 2 项）"
fi

if (( vendor_target_ready == 1 )) && [[ -s "$vendor_prop_patch" ]]; then
	vendor_prop_count="$(awk 'END { print NR }' "$vendor_prop_patch")"
	merge_prop_file "$vendor_prop_patch" "$vendor_build_prop"
	std_print "✅ 原包 vendor 的 $vendor_prop_count 项显示属性已合并到 vendor/build.prop"
fi
std_print "处理完成"
