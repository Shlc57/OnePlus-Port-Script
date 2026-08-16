#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "从小米原包 mi_odm 写入设备标识"
std_print

for part_name in mi_odm odm system; do
	check_part_exists "$part_name"
done

source_build_prop="$project_dir/mi_odm/etc/build.prop"
check_file_exists "$source_build_prop"

override_prop_name="${DEVICE_IDENTITY_PROP:-}"
override_prop_file=""
source_prop_files=("$source_build_prop")
if [[ -n "$override_prop_name" ]]; then
	if [[ ! "$override_prop_name" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*\.prop$ ]]; then
		err_print "无效的设备标识覆盖文件名：$override_prop_name"
		exit 1
	fi
	override_prop_file="$project_dir/mi_odm/etc/$override_prop_name"
	validate_prop_file "$override_prop_file"
	source_prop_files+=("$override_prop_file")
	std_print "身份来源：mi_odm/build.prop + mi_odm/etc/$override_prop_name"
else
	std_print "身份来源：mi_odm/build.prop"
fi

odm_build_props=(
	"$project_dir/odm/build.prop"
	"$project_dir/odm/etc/build.prop"
)
system_build_prop="$project_dir/system/system/build.prop"

for build_prop in "${odm_build_props[@]}" "$system_build_prop"; do
	check_file_exists "$build_prop"
	if [[ -L "$build_prop" ]]; then
		err_print "不支持直接修改符号链接：$build_prop"
		exit 1
	fi
done

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
for prop_key in "${identity_keys[@]}"; do
	prop_value="$(read_prop_value "$prop_key" "${source_prop_files[@]}")"
	if [[ -z "$prop_value" ]]; then
		err_print "来源属性值不能为空：$prop_key"
		exit 1
	fi
	identity_values["$prop_key"]="$prop_value"
done

if [[ -n "$override_prop_file" ]]; then
	for build_prop in "${odm_build_props[@]}"; do
		merge_prop_file "$override_prop_file" "$build_prop"
	done
	std_print "✅ 指定 prop 的全部有效属性已合并到 odm"
fi

for build_prop in "${odm_build_props[@]}"; do
	for prop_key in "${identity_keys[@]}"; do
		ensure_prop "$build_prop" "$prop_key" "${identity_values[$prop_key]}"
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
for index in "${!system_source_keys[@]}"; do
	source_key="${system_source_keys[$index]}"
	target_key="${system_target_keys[$index]}"
	ensure_prop "$system_build_prop" "$target_key" "${identity_values[$source_key]}"
done

std_print "✅ 已写入：${identity_values[ro.product.odm.marketname]}（${identity_values[ro.product.odm.model]}）"
std_print "处理完成"
