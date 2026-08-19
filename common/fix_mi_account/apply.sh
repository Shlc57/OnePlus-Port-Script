#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复小米账号"
std_print
std_print "方案来自 DNA 群 @夜陌、皮神，本人仅负责插件整合"
std_print "从小米原包分区动态提取资源，不使用模块内二进制载荷"
std_print "mi_odm、mi_vendor 仅作为来源，最终目标保持 odm、vendor 真实分区名"
std_print

source_parts=(mi_odm mi_vendor)
target_parts=(odm vendor)
manifests=(
	"$patcher_dir/config/mi_odm_sources.tsv"
	"$patcher_dir/config/mi_vendor_sources.tsv"
)
exec_context_overrides="$patcher_dir/config/exec_context_overrides.tsv"
# shellcheck disable=SC2154 # project_dir 由 init_port_env/tools.sh 导出。
exec_transition_cil="$project_dir/system/system/etc/selinux/plat_sepolicy.cil"
selinux_bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
runtime_file_contexts=(
	"$project_dir/odm/etc/selinux/precompiled_file_contexts"
	"$project_dir/vendor/etc/selinux/vendor_file_contexts"
)

validate_selinux_bundle_sources() {
	local requirement_path
	local source_part
	local target_part
	local relative_path
	local source_file
	local manifest_file

	for requirement_path in "${SELINUX_BUNDLE_REQUIREMENTS[@]}"; do
		case "$requirement_path" in
			odm/*)
				source_part="mi_odm"
				target_part="odm"
				manifest_file="${manifests[0]}"
				;;
			vendor/*)
				source_part="mi_vendor"
				target_part="vendor"
				manifest_file="${manifests[1]}"
				;;
			*)
				err_print "账号 SELinux bundle 必需文件不属于 odm/vendor：$requirement_path"
				return 1
				;;
		esac
		relative_path="${requirement_path#"$target_part/"}"
		source_file="$project_dir/$source_part/$relative_path"
		check_file_exists "$source_file" || return 1
		if [[ -L "$source_file" ]]; then
			err_print "账号 SELinux bundle 来源不能是符号链接：$source_file"
			return 1
		fi
		if ! awk -F '\t' -v wanted="$relative_path" '
			$1 !~ /^#/ && $2 == wanted { found = 1 }
			END { exit(found ? 0 : 1) }
		' "$manifest_file"; then
			err_print "账号 SELinux bundle 必需文件未列入来源清单：$requirement_path"
			return 1
		fi
	done
}

validate_mtd_service_contract() {
	local odm_root="${1:-}"
	local mtd_service_rc="$odm_root/etc/init/vendor.xiaomi.hardware.aidl.mtdservice-service.rc"
	local mtd_check_rc="$odm_root/etc/init/vendor.xiaomi.hardware.aidl.mtd_check-service.rc"
	local mtkeysoter_service_rc="$odm_root/etc/init/vendor.xiaomi.hardware.aidl.mtkeysoter-service.rc"

	for required_rc in "$mtd_service_rc" "$mtd_check_rc" "$mtkeysoter_service_rc"; do
		check_file_exists "$required_rc" || return 1
		if [[ -L "$required_rc" ]]; then
			err_print "账号 mtdservice rc 不能是符号链接：$required_rc"
			return 1
		fi
	done
	if ! grep -Fqx 'service vendor.mtdservice /odm/bin/mtd' "$mtd_service_rc"; then
		err_print "mtdservice rc 的服务入口与账号 SELinux bundle 不一致"
		return 1
	fi
	if ! grep -Fqx 'service vendor.mtd_check /odm/bin/mtd_check' "$mtd_check_rc"; then
		err_print "mtd_check rc 的服务入口与账号 SELinux bundle 不一致"
		return 1
	fi
	if ! grep -Fqx '    mkdir /data/vendor/images 0770 system system' "$mtd_check_rc"; then
		err_print "mtd_check rc 缺少 /data/vendor/images 初始化契约"
		return 1
	fi
	if ! grep -Fqx 'service vendor.mtkeysoter /odm/bin/mtd_keysoter' "$mtkeysoter_service_rc"; then
		err_print "mtkeysoter rc 的服务入口与账号 SELinux bundle 不一致"
		return 1
	fi
	if ! grep -Fqx \
		'    interface aidl vendor.xiaomi.hardware.aidl.mtkeysoter.IMTKeysoterService/default' \
		"$mtkeysoter_service_rc"; then
		err_print "mtkeysoter rc 缺少与 service_contexts 一致的 AIDL interface"
		return 1
	fi
}

validate_exec_context_overrides() {
	local override_file="${1:-}"
	local policy_contexts="${2:-}"
	local context_path
	local context_value
	local extra_field
	local normalized_path
	local partition_name
	local relative_path
	local source_part
	local manifest_file
	local entry_count=0
	declare -A seen_paths=()

	check_file_exists "$override_file" || return 1
	check_file_exists "$policy_contexts" || return 1
	while IFS=$'\t' read -r context_path context_value extra_field || [[ -n "$context_path" || -n "$context_value" ]]; do
		context_path="${context_path%$'\r'}"
		context_value="${context_value%$'\r'}"
		extra_field="${extra_field%$'\r'}"
		[[ -z "$context_path" || "$context_path" == \#* ]] && continue
		if [[ -z "$context_value" || -n "$extra_field" ]]; then
			err_print "执行上下文覆盖清单格式错误：$override_file"
			return 1
		fi
		normalized_path="${context_path//\\/}"
		case "$normalized_path" in
			/odm/*)
				partition_name="odm"
				source_part="mi_odm"
				manifest_file="${manifests[0]}"
				;;
			/vendor/*)
				partition_name="vendor"
				source_part="mi_vendor"
				manifest_file="${manifests[1]}"
				;;
			*)
				err_print "执行上下文覆盖路径不属于 odm/vendor：$context_path"
				return 1
				;;
		esac
		relative_path="${normalized_path#"/$partition_name/"}"
		if ! _is_safe_relative_path "$relative_path"; then
			err_print "执行上下文覆盖路径不安全：$context_path"
			return 1
		fi
		if [[ -n "${seen_paths[$normalized_path]+present}" ]]; then
			err_print "执行上下文覆盖路径重复：$context_path"
			return 1
		fi
		seen_paths["$normalized_path"]=1
		if [[ ! "$context_value" =~ ^u:object_r:[A-Za-z0-9_]+:s0$ ]]; then
			err_print "执行上下文格式无效：$context_value"
			return 1
		fi
		if ! awk -v wanted="$context_value" '$2 == wanted { found = 1 } END { exit(found ? 0 : 1) }' "$policy_contexts"; then
			err_print "目标策略未使用执行上下文：$context_value"
			return 1
		fi
		check_file_exists "$project_dir/$source_part/$relative_path" || return 1
		if ! awk -F '\t' -v wanted="$relative_path" '
			$1 !~ /^#/ && $2 == wanted { found = 1 }
			END { exit(found ? 0 : 1) }
		' "$manifest_file"; then
			err_print "执行上下文覆盖路径未列入来源清单：$relative_path"
			return 1
		fi
		entry_count=$((entry_count + 1))
	done < "$override_file"
	if (( entry_count == 0 )); then
		err_print "执行上下文覆盖清单为空：$override_file"
		return 1
	fi
}

merge_exec_context_overrides() {
	local override_file="${1:-}"
	local destination_contexts="${2:-}"
	local partition_prefix="${3:-}"

	check_file_exists "$override_file" || return 1
	check_file_exists "$destination_contexts" || return 1
	if [[ -n "$partition_prefix" && ! "$partition_prefix" =~ ^/(odm|vendor)/$ ]]; then
		err_print "执行上下文覆盖分区前缀无效：$partition_prefix"
		return 1
	fi
	merge_contexts_file "$override_file" "$destination_contexts" "$partition_prefix"
}

check_file_exists "$exec_context_overrides"
check_file_exists "$exec_transition_cil"
load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"
validate_selinux_bundle_sources
validate_mtd_service_contract "$project_dir/mi_odm"
for runtime_contexts in "${runtime_file_contexts[@]}"; do
	check_file_exists "$runtime_contexts"
done
if ! grep -Fqx \
	'(typetransition init hal_allocator_default_exec process hal_allocator_default)' \
	"$exec_transition_cil"; then
	err_print "目标策略缺少 hal_allocator_default 执行域转换"
	exit 1
fi
validate_exec_context_overrides \
	"$exec_context_overrides" \
	"${runtime_file_contexts[0]}"

for index in "${!source_parts[@]}"; do
	source_part="${source_parts[$index]}"
	target_part="${target_parts[$index]}"
	source_contexts="$(get_part_contexts_path "$source_part")"
	target_contexts="$(get_part_contexts_path "$target_part")"
	source_fsconfig="$(get_part_fsconfig_path "$source_part")"
	target_fsconfig="$(get_part_fsconfig_path "$target_part")"

	check_part_exists "$source_part"
	check_part_exists "$target_part"
	check_file_exists "${manifests[$index]}"
	check_file_exists "$source_contexts"
	check_file_exists "$target_contexts"
	check_file_exists "$source_fsconfig"
	check_file_exists "$target_fsconfig"
	validate_source_file_manifest \
		"$project_dir/$source_part" \
		"$project_dir/$target_part" \
		"${manifests[$index]}"
	validate_translated_contexts \
		"$source_contexts" \
		"${manifests[$index]}" \
		"/$source_part" \
		"/$target_part"
	validate_translated_fsconfig \
		"$source_fsconfig" \
		"${manifests[$index]}" \
		"$source_part" \
		"$target_part"
done

for index in "${!source_parts[@]}"; do
	source_part="${source_parts[$index]}"
	target_part="${target_parts[$index]}"
	manifest_file="${manifests[$index]}"
	source_contexts="$(get_part_contexts_path "$source_part")"
	target_contexts="$(get_part_contexts_path "$target_part")"
	source_fsconfig="$(get_part_fsconfig_path "$source_part")"
	target_fsconfig="$(get_part_fsconfig_path "$target_part")"

	std_print "开始处理：$source_part → $target_part"
	apply_source_file_manifest \
		"$project_dir/$source_part" \
		"$project_dir/$target_part" \
		"$manifest_file"
	merge_translated_contexts \
		"$source_contexts" \
		"$target_contexts" \
		"/$source_part" \
		"/$target_part" \
		"$manifest_file"
	merge_translated_fsconfig \
		"$source_fsconfig" \
		"$target_fsconfig" \
		"$source_part" \
		"$target_part" \
		"$manifest_file"
	std_print "✅ $source_part → $target_part 文件、contexts 与 fsconfig 已合并"
done

merge_exec_context_overrides \
	"$exec_context_overrides" \
	"$(get_part_contexts_path odm)" \
	"/odm/"
merge_exec_context_overrides \
	"$exec_context_overrides" \
	"$(get_part_contexts_path vendor)" \
	"/vendor/"
for runtime_contexts in "${runtime_file_contexts[@]}"; do
	merge_exec_context_overrides \
		"$exec_context_overrides" \
		"$runtime_contexts"
done
std_print "✅ Xiaomi 账号其余兼容 daemon 执行上下文已映射到目标域"

check_selinux_bundle_requirements "$project_dir"
if [[ "$SELINUX_BUNDLE_ACTIVE" != true ]]; then
	err_print "账号 SELinux bundle 未形成完整的目标交付物"
	exit 1
fi
validate_mtd_service_contract "$project_dir/odm"
std_print "✅ 已整理 mtd 独立域策略与 contexts bundle，交由下游 common/fix_vendor_avc 统一合并"

std_print "处理完成"
