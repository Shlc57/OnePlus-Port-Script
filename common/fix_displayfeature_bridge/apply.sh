#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "接入 Xiaomi DisplayFeature 到底包 QTI 显示栈"
std_print "保留 Xiaomi AIDL 上层，仅用轻量 legacy HAL 桥替换完整 Xiaomi 显示 HAL"
std_print

source_manifest="$patcher_dir/config/mi_vendor_sources.tsv"
file_context_overrides="$patcher_dir/config/file_context_overrides.tsv"
service_context_overrides="$patcher_dir/config/service_context_overrides.tsv"
clean_rc="$patcher_dir/config/vendor.xiaomi.hardware.displayfeature_aidl-service.rc"
bridge_so="$patcher_dir/prebuilt/odm/lib64/hw/displayfeature.default.so"
bridge_input_stamp="$bridge_so.inputs.sha256"
bridge_build_script="$patcher_dir/build.sh"
bridge_source="$patcher_dir/src/displayfeature_bridge.cpp"
bridge_hardware_compat_header="$patcher_dir/include/hardware_compat.h"
bridge_platform_binder_compat_header="$patcher_dir/include/platform_binder_compat.h"

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
source_contexts="$(get_part_contexts_path mi_vendor)"
vendor_contexts="$(get_part_contexts_path vendor)"
odm_contexts="$(get_part_contexts_path odm)"
source_fsconfig="$(get_part_fsconfig_path mi_vendor)"
vendor_fsconfig="$(get_part_fsconfig_path vendor)"
odm_fsconfig="$(get_part_fsconfig_path odm)"
# shellcheck disable=SC2154
vendor_file_contexts="$project_dir/vendor/etc/selinux/vendor_file_contexts"
precompiled_file_contexts="$project_dir/odm/etc/selinux/precompiled_file_contexts"
vendor_service_contexts="$project_dir/vendor/etc/selinux/vendor_service_contexts"
precompiled_service_contexts="$project_dir/odm/etc/selinux/precompiled_service_contexts"
vendor_policy="$project_dir/vendor/etc/selinux/vendor_sepolicy.cil"
vndservice_contexts="$project_dir/vendor/etc/selinux/vndservice_contexts"

calculate_bridge_input_hash() {
	sha256sum \
		"$bridge_build_script" \
		"$bridge_source" \
		"$bridge_hardware_compat_header" \
		"$bridge_platform_binder_compat_header" | \
		awk '{print $1}' | sha256sum | awk '{print $1}'
}

validate_bridge_prebuilt() {
	local bridge_input
	local recorded_hash
	local extra_field
	local current_hash

	for bridge_input in \
		"$bridge_build_script" \
		"$bridge_source" \
		"$bridge_hardware_compat_header" \
		"$bridge_platform_binder_compat_header"; do
		check_file_exists "$bridge_input" || return 1
	done
	if [[ ! -f "$bridge_input_stamp" ]]; then
		err_print "DisplayFeature 桥预编译库缺少输入哈希，不能确认其对应当前源码"
		err_print "请先执行：$bridge_build_script"
		return 1
	fi
	read -r recorded_hash extra_field < "$bridge_input_stamp" || true
	if [[ ! "$recorded_hash" =~ ^[0-9a-fA-F]{64}$ || -n "${extra_field:-}" ]]; then
		err_print "DisplayFeature 桥输入哈希文件无效：$bridge_input_stamp"
		err_print "请重新执行：$bridge_build_script"
		return 1
	fi
	current_hash="$(calculate_bridge_input_hash)"
	if [[ "$recorded_hash" != "$current_hash" ]]; then
		err_print "DisplayFeature 桥预编译库已落后于当前源码，拒绝写入 odm"
		err_print "recorded=$recorded_hash"
		err_print "current=$current_hash"
		err_print "请先执行：$bridge_build_script"
		return 1
	fi
}

validate_file_context_overrides() {
	local override_file="${1:-}"
	local context_path
	local context_value
	local extra_field
	local normalized_path
	local entry_count=0
	declare -A seen_paths=()

	check_file_exists "$override_file" || return 1
	while IFS=$'\t' read -r context_path context_value extra_field || [[ -n "$context_path" || -n "$context_value" ]]; do
		context_path="${context_path%$'\r'}"
		context_value="${context_value%$'\r'}"
		extra_field="${extra_field%$'\r'}"
		[[ -z "$context_path" || "$context_path" == \#* ]] && continue
		if [[ -z "$context_value" || -n "$extra_field" ]]; then
			err_print "file_contexts 覆盖清单格式错误：$override_file"
			return 1
		fi
		normalized_path="${context_path//\\/}"
		case "$normalized_path" in
			/vendor/bin/hw/vendor.xiaomi.hardware.displayfeature_aidl-service|/odm/lib64/hw/displayfeature.default.so)
				;;
			*)
				err_print "file_contexts 覆盖路径不属于 DisplayFeature 桥：$context_path"
				return 1
				;;
		esac
		if [[ -n "${seen_paths[$normalized_path]+present}" ]]; then
			err_print "file_contexts 覆盖路径重复：$context_path"
			return 1
		fi
		seen_paths["$normalized_path"]=1
		if [[ ! "$context_value" =~ ^u:object_r:[A-Za-z0-9_]+:s0$ ]]; then
			err_print "file_contexts 上下文格式无效：$context_value"
			return 1
		fi
		entry_count=$((entry_count + 1))
	done < "$override_file"
	if (( entry_count != 2 )); then
		err_print "file_contexts 覆盖清单必须包含服务和 HAL 两项：$override_file"
		return 1
	fi
}

validate_service_context_overrides() {
	local override_file="${1:-}"
	local service_name
	local context_value
	local extra_field
	local entry_count=0

	check_file_exists "$override_file" || return 1
	while IFS=$'\t' read -r service_name context_value extra_field || [[ -n "$service_name" || -n "$context_value" ]]; do
		service_name="${service_name%$'\r'}"
		context_value="${context_value%$'\r'}"
		extra_field="${extra_field%$'\r'}"
		[[ -z "$service_name" || "$service_name" == \#* ]] && continue
		if [[ "$service_name" != "vendor.xiaomi.hardware.displayfeature_aidl.IDisplayFeature/default" || \
			"$context_value" != "u:object_r:vendor_hal_display_color_aidl_service:s0" || \
			-n "$extra_field" ]]; then
			err_print "service_contexts 覆盖清单格式或内容错误：$override_file"
			return 1
		fi
		entry_count=$((entry_count + 1))
	done < "$override_file"
	if (( entry_count != 1 )); then
		err_print "service_contexts 覆盖清单必须只有一项：$override_file"
		return 1
	fi
}

merge_file_context_overrides() {
	local override_file="${1:-}"
	local destination_contexts="${2:-}"
	local partition_prefix="${3:-}"

	check_file_exists "$override_file" || return 1
	check_file_exists "$destination_contexts" || return 1
	if [[ -n "$partition_prefix" && ! "$partition_prefix" =~ ^/(odm|vendor)/$ ]]; then
		err_print "file_contexts 覆盖分区前缀无效：$partition_prefix"
		return 1
	fi
	merge_contexts_file "$override_file" "$destination_contexts" "$partition_prefix"
}

merge_service_context_overrides() {
	local override_file="${1:-}"
	local destination_contexts="${2:-}"

	check_file_exists "$override_file" || return 1
	check_file_exists "$destination_contexts" || return 1
	merge_contexts_file "$override_file" "$destination_contexts"
}

install_text_preserving_mode() {
	local source_file="${1:-}"
	local target_file="${2:-}"
	local temporary_file

	check_file_exists "$source_file" || return 1
	check_file_exists "$target_file" || return 1
	temporary_file="$(mktemp "${target_file}.tmp.XXXXXX")" || return 1
	if ! cp -- "$source_file" "$temporary_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
	_install_generated_file "$temporary_file" "$target_file"
}

merge_surfaceflinger_policy_rules() {
	local policy_file="${1:-}"
	local surfaceflinger_type
	local surfaceflinger_service_type
	local temporary_file
	local policy_rule
	local -a surfaceflinger_types=()
	local -a surfaceflinger_service_types=()
	local -a policy_rules=()

	check_file_exists "$policy_file" || return 1
	mapfile -t surfaceflinger_types < <(
		grep -oE 'surfaceflinger_[0-9]+' "$policy_file" | sort -u
	)
	mapfile -t surfaceflinger_service_types < <(
		grep -oE 'surfaceflinger_service_[0-9]+' "$policy_file" | sort -u
	)
	if (( ${#surfaceflinger_types[@]} != 1 )); then
		err_print "无法唯一确定目标 vendor 策略中的 SurfaceFlinger 域类型"
		return 1
	fi
	if (( ${#surfaceflinger_service_types[@]} != 1 )); then
		err_print "无法唯一确定目标 vendor 策略中的 SurfaceFlinger 服务类型"
		return 1
	fi

	surfaceflinger_type="${surfaceflinger_types[0]}"
	surfaceflinger_service_type="${surfaceflinger_service_types[0]}"
	policy_rules=(
		"(allow vendor_hal_display_color_default $surfaceflinger_type (binder (call)))"
		"(allow vendor_hal_display_color_default $surfaceflinger_service_type (service_manager (find)))"
	)

	temporary_file="$(mktemp "${policy_file}.tmp.XXXXXX")" || return 1
	if ! cp -- "$policy_file" "$temporary_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
	for policy_rule in "${policy_rules[@]}"; do
		if ! grep -Fqx "$policy_rule" "$temporary_file"; then
			printf '%s\n' "$policy_rule" >> "$temporary_file"
		fi
	done
	_install_generated_file "$temporary_file" "$policy_file"
}

validate_qdcm_render_intents() {
	local display_dir
	local calibration_file
	local intent
	local intent_name
	local matched
	local -a calibration_files=()

	for display_dir in \
		"$project_dir/odm/etc/display" \
		"$project_dir/vendor/etc/display"; do
		[[ -d "$display_dir" ]] || continue
		while IFS= read -r -d '' calibration_file; do
			calibration_files+=("$calibration_file")
		done < <(find "$display_dir" -maxdepth 1 -type f -name 'qdcm_calib_data_*.json' -print0)
	done

	if (( ${#calibration_files[@]} == 0 )); then
		err_print "底包缺少 QDCM 面板调色数据"
		return 1
	fi

	while read -r intent intent_name; do
		matched=false
		for calibration_file in "${calibration_files[@]}"; do
			if grep -Eq "\"RenderIntent\"[[:space:]]*:[[:space:]]*$intent([[:space:]]*[,}])" \
				"$calibration_file" && \
				grep -Eq "\"RenderIntentName\"[[:space:]]*:[[:space:]]*\"$intent_name\"" \
				"$calibration_file"; then
				matched=true
				break
			fi
		done
		if [[ "$matched" != true ]]; then
			err_print "底包 QDCM 数据缺少 RenderIntent：$intent ($intent_name)"
			return 1
		fi
	done <<'EOF'
301 StandardSRGB
303 DefaultSRGB
307 EnhanceSRGB
EOF
}

for part_name in mi_vendor vendor odm; do
	check_part_exists "$part_name"
done

for required_file in \
	"$source_manifest" \
	"$file_context_overrides" \
	"$service_context_overrides" \
	"$clean_rc" \
	"$bridge_so" \
	"$source_contexts" \
	"$vendor_contexts" \
	"$odm_contexts" \
	"$source_fsconfig" \
	"$vendor_fsconfig" \
	"$odm_fsconfig" \
	"$vendor_file_contexts" \
	"$precompiled_file_contexts" \
	"$vendor_service_contexts" \
	"$precompiled_service_contexts" \
	"$vendor_policy" \
	"$vndservice_contexts" \
	"$project_dir/vendor/lib64/libqservice.so" \
	"$project_dir/vendor/lib64/libsdmclient.so" \
	"$project_dir/vendor/lib64/libsdm-disp-vndapis.so"; do
	check_file_exists "$required_file"
done

validate_bridge_prebuilt
validate_source_file_manifest \
	"$project_dir/mi_vendor" \
	"$project_dir/vendor" \
	"$source_manifest"
validate_translated_contexts \
	"$source_contexts" \
	"$source_manifest" \
	/mi_vendor \
	/vendor
validate_translated_fsconfig \
	"$source_fsconfig" \
	"$source_manifest" \
	mi_vendor \
	vendor
validate_file_context_overrides "$file_context_overrides"
validate_service_context_overrides "$service_context_overrides"
validate_qdcm_render_intents

if grep -Eq 'mi_display|/vendor/bin/displayfeature|restart[[:space:]]+displayfeature|hist_event|mipi_reg|tracing_mark_write' "$clean_rc"; then
	err_print "清理版 DisplayFeature rc 仍包含 Xiaomi 下层节点或缺失服务引用"
	exit 1
fi
if ! grep -Fqx \
	'    interface aidl vendor.xiaomi.hardware.displayfeature_aidl.IDisplayFeature/default' \
	"$clean_rc"; then
	err_print "清理版 DisplayFeature rc 缺少 AIDL interface 声明"
	exit 1
fi

if ! grep -Eq '^\(typetransition init(_[A-Za-z0-9]+)? vendor_hal_display_color_default_exec process vendor_hal_display_color_default\)$' "$vendor_policy"; then
	err_print "目标策略缺少 QTI Display Color 执行域转换"
	exit 1
fi
for policy_rule in \
	'(allow vendor_hal_display_color vendor_qdisplay_service (service_manager (find)))' \
	'(allow vendor_hal_display_color_server vendor_hal_display_color_aidl_service (service_manager (add find)))'; do
	if ! grep -Fqx "$policy_rule" "$vendor_policy"; then
		err_print "目标策略缺少 DisplayFeature 桥所需权限：$policy_rule"
		exit 1
	fi
done
if ! grep -Eq '^display\.qservice[[:space:]]+u:object_r:vendor_qdisplay_service:s0$' "$vndservice_contexts"; then
	err_print "底包缺少 display.qservice 的 vndservice context"
	exit 1
fi

apply_source_file_manifest \
	"$project_dir/mi_vendor" \
	"$project_dir/vendor" \
	"$source_manifest"
merge_translated_contexts \
	"$source_contexts" \
	"$vendor_contexts" \
	/mi_vendor \
	/vendor \
	"$source_manifest"
merge_translated_fsconfig \
	"$source_fsconfig" \
	"$vendor_fsconfig" \
	mi_vendor \
	vendor \
	"$source_manifest"

install_text_preserving_mode \
	"$clean_rc" \
	"$project_dir/vendor/etc/init/vendor.xiaomi.hardware.displayfeature_aidl-service.rc"
replace_file_if_different \
	"$bridge_so" \
	"$project_dir/odm/lib64/hw/displayfeature.default.so"
chmod 0644 -- "$project_dir/odm/lib64/hw/displayfeature.default.so"
ensure_part_fsconfig_entry odm lib64/hw/displayfeature.default.so 0 0 0644

merge_file_context_overrides "$file_context_overrides" "$vendor_contexts" /vendor/
merge_file_context_overrides "$file_context_overrides" "$odm_contexts" /odm/
merge_file_context_overrides "$file_context_overrides" "$vendor_file_contexts" /vendor/
merge_file_context_overrides "$file_context_overrides" "$precompiled_file_contexts"
merge_service_context_overrides "$service_context_overrides" "$vendor_service_contexts"
merge_service_context_overrides "$service_context_overrides" "$precompiled_service_contexts"
merge_surfaceflinger_policy_rules "$vendor_policy"

std_print "✅ Xiaomi AIDL DisplayFeature 已映射到 QTI Display Color 兼容域"
std_print "✅ 轻量 displayfeature.default.so 已写入真实 odm 分区"
std_print "✅ DisplayFeature 桥已获准访问 system SurfaceFlinger 色彩矩阵接口"
std_print "处理完成"
