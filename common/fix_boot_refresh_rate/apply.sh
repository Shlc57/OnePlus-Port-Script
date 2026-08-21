#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复开机刷新率与刷新率/分辨率切换"
std_print "刷新率：从底包显示栈自动识别并生成属性与机型列表"
std_print "显示策略：从目标设备显式配置合并其余显示与触控属性"
std_print "分辨率：跟随底包 sdm_display_resolution_extn.xml"
std_print

# init_port_env 注入当前移植工程根目录和补丁仓库根目录。
# shellcheck disable=SC2154
vendor_build_prop="$project_dir/vendor/build.prop"
odm_build_prop="$project_dir/odm/etc/build.prop"
display_init_script="$project_dir/vendor/bin/init.qti.display_boot.sh"
advanced_refresh_config="$project_dir/vendor/etc/display/advanced_sf_offsets.xml"
display_resolution_config="$project_dir/odm/etc/sdm_display_resolution_extn.xml"
device_features_dir="$project_dir/product/etc/device_features"
device_feature_xml="$PORT_SOURCE_DEVICE_FEATURE_FILE"
settings_apk="$project_dir/system_ext/priv-app/Settings/Settings.apk"
settings_oat_dir="$project_dir/system_ext/priv-app/Settings/oat"
# shellcheck disable=SC2154
settings_patcher="$port_dir/common/settings_apk_patcher.sh"
refresh_parser="$patcher_dir/refresh_rate.py"
odm_policy_source="${DISPLAY_POLICY_ODM_PROPERTIES_FILE:-}"
vendor_policy_source="${DISPLAY_POLICY_VENDOR_PROPERTIES_FILE:-}"
odm_policy_list="$patcher_dir/config/odm_props.list"
vendor_policy_list="$patcher_dir/config/vendor_props.list"

optional_regular_file() {
	local file_path="${1:-}"
	local description="${2:-文件}"

	if [[ -L "$file_path" ]]; then
		err_print "$description 不能是符号链接：$file_path"
		return 2
	elif [[ ! -e "$file_path" ]]; then
		warn_print "$description 不存在，跳过对应子步骤：${file_path#"$project_dir"/}"
		return 1
	elif [[ ! -f "$file_path" ]]; then
		err_print "$description 不是普通文件：$file_path"
		return 2
	fi
}

build_policy_patch() {
	local source_file="${1:-}"
	local prop_list="${2:-}"
	local output_file="${3:-}"
	local source_name="${4:-显示策略}"
	local raw_line
	local prop_key
	local prop_value
	local listed_prop_count=0
	local prop_count=0
	local -A seen_keys=()

	: > "$output_file"
	if [[ -z "$source_file" ]]; then
		warn_print "未提供 $source_name 配置，跳过其余显示与触控策略"
		return 0
	fi
	if [[ -L "$source_file" ]]; then
		err_print "$source_name 配置不能是符号链接：$source_file"
		return 1
	elif [[ ! -e "$source_file" ]]; then
		warn_print "$source_name 配置不存在，跳过其余显示与触控策略：$source_file"
		return 0
	elif [[ ! -f "$source_file" ]]; then
		err_print "$source_name 配置不是普通文件：$source_file"
		return 1
	fi
	validate_prop_file "$source_file" || return 1
	if [[ -L "$prop_list" ]]; then
		err_print "显示策略属性清单不能是符号链接：$prop_list"
		return 1
	elif [[ ! -e "$prop_list" ]]; then
		warn_print "显示策略属性清单不存在，跳过：${prop_list#"$port_dir"/}"
		return 0
	elif [[ ! -f "$prop_list" ]]; then
		err_print "显示策略属性清单不是普通文件：$prop_list"
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
			err_print "显示策略属性清单存在无效属性名：$prop_list：$prop_key"
			return 1
		fi
		if [[ -n "${seen_keys[$prop_key]:-}" ]]; then
			err_print "显示策略属性清单存在重复属性：$prop_list：$prop_key"
			return 1
		fi
		seen_keys["$prop_key"]=1
		if ! grep -Eq "^[[:space:]]*${prop_key//./\\.}[[:space:]]*=" "$source_file"; then
			warn_print "显示策略属性不存在，跳过：$source_name 中的 $prop_key"
			continue
		fi
		prop_value="$(read_prop_value "$prop_key" "$source_file")" || return 1
		if [[ -z "$prop_value" ]]; then
			warn_print "显示策略属性值为空，跳过：$source_name 中的 $prop_key"
			continue
		fi
		printf '%s=%s\n' "$prop_key" "$prop_value" >> "$output_file"
		((prop_count += 1))
	done < "$prop_list"
	if (( listed_prop_count == 0 )); then
		warn_print "显示策略属性清单没有有效条目，跳过：${prop_list#"$port_dir"/}"
	elif (( prop_count == 0 )); then
		warn_print "$source_name 没有可合并的其余显示与触控策略"
	fi
}

capability_ready=1
vendor_target_ready=1
for source_spec in \
	"$vendor_build_prop|底包 vendor 属性" \
	"$display_init_script|底包显示启动脚本" \
	"$advanced_refresh_config|底包刷新率配置"; do
	IFS='|' read -r source_path source_description <<< "$source_spec"
	if optional_regular_file "$source_path" "$source_description"; then
		:
	else
		file_status=$?
		if (( file_status == 2 )); then
			exit 1
		fi
		capability_ready=0
		if [[ "$source_path" == "$vendor_build_prop" ]]; then
			vendor_target_ready=0
		fi
	fi
done

odm_target_ready=1
if optional_regular_file "$odm_build_prop" "ODM 属性目标"; then
	:
else
	file_status=$?
	if (( file_status == 2 )); then
		exit 1
	fi
	odm_target_ready=0
fi

feature_patch_ready="$capability_ready"
if (( feature_patch_ready == 0 )); then
	:
elif [[ -z "$device_feature_xml" ]]; then
	warn_print "移植前未识别原包设备代号，跳过刷新率与分辨率机型 XML 子步骤"
	feature_patch_ready=0
elif [[ -L "$device_features_dir" ]]; then
	err_print "device_features 目录不能是符号链接：$device_features_dir"
	exit 1
elif [[ -e "$device_features_dir" && ! -d "$device_features_dir" ]]; then
	err_print "device_features 路径不是普通目录：$device_features_dir"
	exit 1
elif optional_regular_file "$device_feature_xml" "刷新率机型配置"; then
	:
else
	file_status=$?
	if (( file_status == 2 )); then
		exit 1
	fi
	feature_patch_ready=0
fi

resolution_ready=0
if (( feature_patch_ready == 1 )); then
	if optional_regular_file "$display_resolution_config" "底包分辨率配置"; then
		resolution_ready=1
	else
		file_status=$?
		if (( file_status == 2 )); then
			exit 1
		fi
	fi
fi

settings_patch_ready=1
if optional_regular_file "$settings_apk" "待修补的 Settings.apk"; then
	check_file_exists "$settings_patcher"
	check_file_exists "$(get_part_contexts_path system_ext)"
	check_file_exists "$(get_part_fsconfig_path system_ext)"
	check_partition_metadata_tool >/dev/null
else
	file_status=$?
	if (( file_status == 2 )); then
		exit 1
	fi
	settings_patch_ready=0
fi

if (( capability_ready == 1 )); then
	if ! command -v python3 >/dev/null 2>&1; then
		err_print "缺少 Python 3，无法解析底包显示能力"
		exit 1
	fi
	check_file_exists "$refresh_parser"
fi
if (( odm_target_ready == 0 )); then
	capability_prop_ready=0
else
	capability_prop_ready="$capability_ready"
fi
if (( capability_prop_ready == 0 && feature_patch_ready == 0 && settings_patch_ready == 0 && \
	odm_target_ready == 0 && vendor_target_ready == 0 )); then
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

odm_policy_patch="$(mktemp "$(get_config_path '.fix_boot_refresh_rate_odm_policy.XXXXXX')")"
vendor_policy_patch="$(mktemp "$(get_config_path '.fix_boot_refresh_rate_vendor_policy.XXXXXX')")"
temporary_files+=("$odm_policy_patch" "$vendor_policy_patch")
if (( odm_target_ready == 1 )); then
	build_policy_patch "$odm_policy_source" "$odm_policy_list" "$odm_policy_patch" "ODM 显示策略"
fi
if (( vendor_target_ready == 1 )); then
	build_policy_patch "$vendor_policy_source" "$vendor_policy_list" "$vendor_policy_patch" "vendor 显示策略"
fi
odm_policy_present=0
vendor_policy_present=0
if [[ -s "$odm_policy_patch" ]]; then
	odm_policy_present=1
fi
if [[ -s "$vendor_policy_patch" ]]; then
	vendor_policy_present=1
fi

model_file=""
generated_refresh_props=""
temporary_xml=""
platform_name=""
target_version=""
fps_summary=""
panel_summary=""
width_summary=""
if (( capability_prop_ready == 1 || feature_patch_ready == 1 )); then
	model_file="$(mktemp "$(get_config_path '.fix_boot_refresh_rate_model.XXXXXX')")"
	temporary_files+=("$model_file")
	declare -a parser_args=(
		--vendor-prop "$vendor_build_prop"
		--init-script "$display_init_script"
		--advanced-xml "$advanced_refresh_config"
		--model-output "$model_file"
	)

	if (( capability_prop_ready == 1 )); then
		generated_refresh_props="$(mktemp "$(get_config_path '.fix_boot_refresh_rate_props.XXXXXX')")"
		temporary_files+=("$generated_refresh_props")
		parser_args+=(--odm-prop "$odm_build_prop" --props-output "$generated_refresh_props")
	fi
	if (( feature_patch_ready == 1 )); then
		temporary_xml="$(mktemp "${device_feature_xml}.tmp.XXXXXX")"
		temporary_files+=("$temporary_xml")
		parser_args+=(--feature-input "$device_feature_xml" --feature-output "$temporary_xml")
		if (( resolution_ready == 1 )); then
			parser_args+=(--resolution-xml "$display_resolution_config")
		fi
	fi

	PYTHONDONTWRITEBYTECODE=1 python3 "$refresh_parser" "${parser_args[@]}"
	if (( capability_prop_ready == 1 )); then
		validate_prop_file "$generated_refresh_props"
	fi
	IFS=$'\t' read -r platform_name target_version fps_summary panel_summary width_summary < <(
		PYTHONDONTWRITEBYTECODE=1 python3 - "$model_file" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as input_file:
    model = json.load(input_file)

fps = "、".join(str(value) for value in model["fps"])
panels = "、".join(f"{width}x{height}" for width, height in model.get("panels", []))
widths = "、".join(str(value) for value in model.get("widths", []))
print(model["platform"], model["target_version"], fps, panels, widths, sep="\t")
PY
	)
fi

odm_merge_patch=""
if (( odm_policy_present == 1 )); then
	odm_merge_patch="$odm_policy_patch"
fi
if (( capability_prop_ready == 1 )); then
	if [[ -n "$odm_merge_patch" ]]; then
		while IFS= read -r refresh_prop || [[ -n "$refresh_prop" ]]; do
			printf '%s\n' "$refresh_prop" >> "$odm_merge_patch"
		done < "$generated_refresh_props"
		validate_prop_file "$odm_merge_patch"
	else
		odm_merge_patch="$generated_refresh_props"
	fi
fi

if (( settings_patch_ready == 1 )); then
	bash "$settings_patcher" screen-resolution "$settings_apk"
	remove_path_if_exists "$settings_oat_dir"
	remove_part_metadata_prefix system_ext priv-app/Settings/oat
fi
if [[ -n "$odm_merge_patch" && -s "$odm_merge_patch" ]]; then
	merge_prop_file "$odm_merge_patch" "$odm_build_prop"
fi
if (( vendor_policy_present == 1 )); then
	merge_prop_file "$vendor_policy_patch" "$vendor_build_prop"
fi
if (( feature_patch_ready == 1 )); then
	_install_generated_file "$temporary_xml" "$device_feature_xml"
fi

if (( capability_prop_ready == 1 || feature_patch_ready == 1 )); then
	std_print "✅ 底包显示平台：$platform_name（target.version=$target_version）"
	std_print "✅ 自动识别刷新率：${fps_summary}Hz"
fi
if (( capability_prop_ready == 1 )); then
	std_print "✅ 已自动生成并合并 4 项刷新率属性：odm/etc/build.prop"
fi
if (( odm_policy_present == 1 )); then
	std_print "✅ 已合并其余 ODM 显示与触控策略：odm/etc/build.prop"
fi
if (( vendor_policy_present == 1 )); then
	std_print "✅ 已合并其余 vendor 显示策略：vendor/build.prop"
fi
if (( feature_patch_ready == 1 )); then
	std_print "✅ 已更新：product/etc/device_features/$PORT_SOURCE_DEVICE_CODE.xml"
	if (( resolution_ready == 1 )); then
		std_print "✅ 底包分辨率：面板 $panel_summary；可切换宽度 $width_summary"
	else
		warn_print "未更新 screen_resolution_supported，仅更新刷新率列表"
	fi
fi
if (( settings_patch_ready == 1 )); then
	std_print "✅ Settings 高度计算：优先匹配 supported mode 的真实宽高"
fi
std_print "处理完成"
