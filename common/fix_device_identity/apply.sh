#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "写入原包设备标识：${PORT_SOURCE_DEVICE_MARKET_NAME:-${PORT_SOURCE_DEVICE_NAME:-未知}}（${PORT_SOURCE_DEVICE_CODE:-未知}）"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
source_build_prop="$project_dir/mi_odm/etc/build.prop"
override_prop_name="${DEVICE_IDENTITY_PROP:-}"
override_prop_file=""
source_prop_files=()
device_display_name_set=0
device_display_name=""
if [[ -n "${DEVICE_DISPLAY_NAME+x}" && -z "$DEVICE_DISPLAY_NAME" ]]; then
	err_print "DEVICE_DISPLAY_NAME 不能为空"
	exit 1
elif [[ -n "${DEVICE_DISPLAY_NAME+x}" ]]; then
	device_display_name_set=1
	device_display_name="$DEVICE_DISPLAY_NAME"
fi
if [[ -n "$device_display_name" && \
	( "$device_display_name" == *$'\n'* || "$device_display_name" == *$'\r'* ) ]]; then
	err_print "设备显示名不能包含换行符"
	exit 1
elif (( device_display_name_set == 1 )); then
	std_print "设备显示名：$device_display_name（来源：参数 DEVICE_DISPLAY_NAME）"
fi
if [[ -L "$source_build_prop" ]]; then
	err_print "不支持从符号链接读取属性：$source_build_prop"
	exit 1
elif [[ ! -e "$source_build_prop" ]]; then
	warn_print "属性来源不存在，跳过：${source_build_prop#"$project_dir"/}"
elif [[ ! -f "$source_build_prop" ]]; then
	err_print "属性来源不是普通文件：$source_build_prop"
	exit 1
else
	source_prop_files+=("$source_build_prop")
fi

if [[ -n "$override_prop_name" ]]; then
	if [[ ! "$override_prop_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*\.prop$ ]]; then
		err_print "无效的设备标识附加配置文件名：$override_prop_name"
		exit 1
	fi
	override_prop_candidate="$project_dir/mi_odm/etc/$override_prop_name"
	if [[ -L "$override_prop_candidate" ]]; then
		err_print "设备标识附加配置不能是符号链接：$override_prop_candidate"
		exit 1
	elif [[ ! -e "$override_prop_candidate" ]]; then
		warn_print "设备标识附加配置不存在，忽略：mi_odm/etc/$override_prop_name"
	elif [[ ! -f "$override_prop_candidate" ]]; then
		err_print "设备标识附加配置不是普通文件：$override_prop_candidate"
		exit 1
	else
		validate_prop_file "$override_prop_candidate"
		override_prop_file="$override_prop_candidate"
		source_prop_files+=("$override_prop_file")
	fi
fi

if [[ -n "$override_prop_file" && -f "$source_build_prop" ]]; then
	std_print "基础身份来源：mi_odm/etc/build.prop；附加配置：mi_odm/etc/$override_prop_name"
elif [[ -n "$override_prop_file" ]]; then
	std_print "附加配置：mi_odm/etc/$override_prop_name"
elif [[ -f "$source_build_prop" ]]; then
	std_print "基础身份来源：mi_odm/etc/build.prop"
fi

odm_build_props=(
	"$project_dir/odm/build.prop"
	"$project_dir/odm/etc/build.prop"
)
system_build_prop="$project_dir/system/system/build.prop"

available_odm_build_props=()
for build_prop in "${odm_build_props[@]}"; do
	if [[ -L "$build_prop" ]]; then
		err_print "不支持直接修改符号链接：$build_prop"
		exit 1
	elif [[ ! -e "$build_prop" ]]; then
		warn_print "属性目标不存在，跳过：${build_prop#"$project_dir"/}"
		continue
	elif [[ ! -f "$build_prop" ]]; then
		err_print "属性目标不是普通文件：$build_prop"
		exit 1
	fi
	available_odm_build_props+=("$build_prop")
done
system_target_ready=1
if [[ -L "$system_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$system_build_prop"
	exit 1
elif [[ ! -e "$system_build_prop" ]]; then
	warn_print "属性目标不存在，跳过：${system_build_prop#"$project_dir"/}"
	system_target_ready=0
elif [[ ! -f "$system_build_prop" ]]; then
	err_print "属性目标不是普通文件：$system_build_prop"
	exit 1
fi

identity_keys=(
	ro.product.odm.brand
	ro.product.odm.device
	ro.product.odm.manufacturer
	ro.product.odm.model
	ro.product.odm.name
	ro.product.odm.cert
	ro.product.odm.marketname
	ro.product.brand_for_attestation
	ro.product.name_for_attestation
	ro.product.device_for_attestation
	ro.product.manufacturer_for_attestation
	ro.odm.build.version.incremental
)
declare -A identity_values=()
if (( ${#source_prop_files[@]} > 0 )); then
	for prop_key in "${identity_keys[@]}"; do
		prop_found=0
		for source_prop_file in "${source_prop_files[@]}"; do
			if grep -Eq "^[[:space:]]*${prop_key//./\\.}[[:space:]]*=" "$source_prop_file"; then
				prop_found=1
				break
			fi
		done
		if (( prop_found == 0 )); then
			warn_print "来源属性不存在，跳过：$prop_key"
			continue
		fi
		prop_value="$(read_prop_value "$prop_key" "${source_prop_files[@]}")"
		if [[ -z "$prop_value" ]]; then
			warn_print "来源属性值为空，跳过：$prop_key"
			continue
		fi
		identity_values["$prop_key"]="$prop_value"
	done
fi
if (( device_display_name_set == 1 )); then
	identity_values[ro.product.odm.marketname]="$device_display_name"
fi

prop_write_performed=0
if [[ -n "$override_prop_file" ]]; then
	for build_prop in "${available_odm_build_props[@]}"; do
		merge_prop_file "$override_prop_file" "$build_prop"
		prop_write_performed=1
	done
	if (( ${#available_odm_build_props[@]} > 0 )); then
		std_print "✅ 附加 prop 的全部有效属性已合并到 odm"
	fi
fi

for build_prop in "${available_odm_build_props[@]}"; do
	for prop_key in "${identity_keys[@]}"; do
		if [[ -n "${identity_values[$prop_key]+x}" ]]; then
			ensure_prop "$build_prop" "$prop_key" "${identity_values[$prop_key]}"
			prop_write_performed=1
		fi
	done
done

system_source_keys=(
	ro.product.odm.manufacturer
	ro.product.odm.brand
	ro.product.odm.model
	ro.product.odm.name
)
system_target_keys=(
	ro.product.manufacturer
	ro.product.brand
	ro.product.model
	ro.product.name
)
if (( system_target_ready == 1 )); then
	for index in "${!system_source_keys[@]}"; do
		source_key="${system_source_keys[$index]}"
		target_key="${system_target_keys[$index]}"
		if [[ -n "${identity_values[$source_key]+x}" ]]; then
			ensure_prop "$system_build_prop" "$target_key" "${identity_values[$source_key]}"
			prop_write_performed=1
		fi
	done
fi

if (( prop_write_performed == 1 )) && \
	[[ -n "${identity_values[ro.product.odm.marketname]+x}" && -n "${identity_values[ro.product.odm.model]+x}" ]]; then
	std_print "✅ 已写入：${identity_values[ro.product.odm.marketname]}（${identity_values[ro.product.odm.model]}）"
elif (( prop_write_performed == 1 )); then
	std_print "✅ 已完成可用设备标识属性写入"
elif (( ${#source_prop_files[@]} > 0 || ${#available_odm_build_props[@]} > 0 || system_target_ready == 1 )); then
	warn_print "没有可写入的设备标识属性，本补丁未修改 prop"
fi
std_print "处理完成"
