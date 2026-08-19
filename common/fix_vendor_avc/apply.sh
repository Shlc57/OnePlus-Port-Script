#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "统一合并 vendor SELinux 来源策略、DisplayFeature 片段和证据规则"
std_print "规则内容由各补丁提供；common/selinux_merge 负责 ABI、去重和最终 CIL 写回"
std_print

for part_name in vendor mi_vendor system system_ext odm; do
	check_part_exists "$part_name"
done
check_partition_metadata_tool >/dev/null

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
vendor_selinux="$project_dir/vendor/etc/selinux"
source_selinux="$project_dir/mi_vendor/etc/selinux"
system_selinux="$project_dir/system/system/etc/selinux"
system_ext_selinux="$project_dir/system_ext/etc/selinux"
odm_selinux="$project_dir/odm/etc/selinux"
vendor_file_contexts="$vendor_selinux/vendor_file_contexts"
vendor_property_contexts="$vendor_selinux/vendor_property_contexts"
precompiled_file_contexts="$odm_selinux/precompiled_file_contexts"
precompiled_property_contexts="$odm_selinux/precompiled_property_contexts"
vendor_metadata_contexts="$(get_part_contexts_path vendor)"
odm_metadata_contexts="$(get_part_contexts_path odm)"
odm_metadata_fsconfig="$(get_part_fsconfig_path odm)"
policy_patcher="$patcher_dir/patch_vendor_avc_policy.py"
# shellcheck disable=SC2154 # port_dir is exported by init_port_env/tools.sh.
selinux_merger="$port_dir/common/selinux_merge/selinux_merge.py"
display_patch_dir="$port_dir/common/fix_displayfeature_bridge"
display_policy_fragment="$display_patch_dir/config/selinux_policy.cil.in"
display_service_rc="$project_dir/vendor/etc/init/vendor.xiaomi.hardware.displayfeature_aidl-service.rc"

for required_dir in \
	"$vendor_selinux" \
	"$source_selinux" \
	"$system_selinux" \
	"$system_ext_selinux" \
	"$odm_selinux"; do
	if [[ ! -d "$required_dir" || -L "$required_dir" ]]; then
		err_print "SELinux 目录不存在或不是普通目录：$required_dir"
		exit 1
	fi
done

for required_file in \
	"$vendor_selinux/vendor_sepolicy.cil" \
	"$source_selinux/vendor_sepolicy.cil" \
	"$vendor_selinux/plat_sepolicy_vers.txt" \
	"$source_selinux/plat_sepolicy_vers.txt" \
	"$vendor_selinux/genfs_labels_version.txt" \
	"$source_selinux/genfs_labels_version.txt" \
	"$vendor_selinux/plat_pub_versioned.cil" \
	"$system_selinux/plat_sepolicy.cil" \
	"$system_ext_selinux/system_ext_sepolicy.cil" \
	"$vendor_file_contexts" \
	"$vendor_property_contexts" \
	"$precompiled_file_contexts" \
	"$precompiled_property_contexts" \
	"$vendor_metadata_contexts" \
	"$odm_metadata_contexts" \
	"$odm_metadata_fsconfig" \
	"$policy_patcher" \
	"$selinux_merger"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "SELinux 修补输入不能是符号链接：$required_file"
		exit 1
	fi
done

api_version="$(tr -d '[:space:]' < "$vendor_selinux/plat_sepolicy_vers.txt")"
if [[ ! "$api_version" =~ ^[0-9]+$ ]]; then
	err_print "plat_sepolicy_vers.txt 不是单一数字 API 版本：$api_version"
	exit 1
fi

policy_targets=("$vendor_selinux/vendor_sepolicy.cil")
if [[ -e "$vendor_selinux/vendor_sepolicy_debug.cil" || -L "$vendor_selinux/vendor_sepolicy_debug.cil" ]]; then
	if [[ ! -f "$vendor_selinux/vendor_sepolicy_debug.cil" || -L "$vendor_selinux/vendor_sepolicy_debug.cil" ]]; then
		err_print "vendor_sepolicy_debug.cil 不是普通文件：$vendor_selinux/vendor_sepolicy_debug.cil"
		exit 1
	fi
	policy_targets+=("$vendor_selinux/vendor_sepolicy_debug.cil")
fi

temporary_files=()
temporary_dirs=()
cleanup() {
	local temporary_file
	local temporary_dir
	for temporary_file in "${temporary_files[@]}"; do
		rm -f -- "$temporary_file"
	done
	for temporary_dir in "${temporary_dirs[@]}"; do
		rm -rf -- "$temporary_dir"
	done
}
trap cleanup EXIT

vendor_merge_dir="$(mktemp -d "$(get_config_path '.fix_vendor_avc_vendor_merge.XXXXXX')")"
temporary_dirs+=("$vendor_merge_dir")
python3 "$selinux_merger" merge-vendor \
	--target-dir "$vendor_selinux" \
	--source-dir "$source_selinux" \
	--output-dir "$vendor_merge_dir"

merged_or_target() {
	local filename="${1:-}"
	local merged_file="$vendor_merge_dir/$filename"
	local target_file="$vendor_selinux/$filename"
	if [[ -e "$merged_file" || -L "$merged_file" ]]; then
		if [[ ! -f "$merged_file" || -L "$merged_file" ]]; then
			err_print "vendor SELinux 合并输出无效：$merged_file"
			return 1
		fi
		printf '%s\n' "$merged_file"
	else
		printf '%s\n' "$target_file"
	fi
}

effective_vendor_policy="$(merged_or_target vendor_sepolicy.cil)"
effective_vendor_file_contexts="$(merged_or_target vendor_file_contexts)"
effective_vendor_property_contexts="$(merged_or_target vendor_property_contexts)"

temporary_avc_fragment="$(mktemp "$(get_config_path '.fix_vendor_avc_policy_fragment.XXXXXX')")"
temporary_files+=("$temporary_avc_fragment")
common_patcher_args=(
	--platform-policy "$system_selinux/plat_sepolicy.cil"
	--versioned-policy "$vendor_selinux/plat_pub_versioned.cil"
	--system-ext-policy "$system_ext_selinux/system_ext_sepolicy.cil"
	--api-version "$api_version"
)
python3 "$policy_patcher" \
	--policy "$effective_vendor_policy" \
	"${common_patcher_args[@]}" \
	--fragment-output "$temporary_avc_fragment"

policy_fragments=("$temporary_avc_fragment")
display_enabled=false
if [[ -e "$display_service_rc" || -L "$display_service_rc" ]]; then
	if [[ ! -f "$display_service_rc" || -L "$display_service_rc" ]]; then
		err_print "DisplayFeature 服务 rc 不是普通文件：$display_service_rc"
		exit 1
	fi
	if ! grep -Fqx \
		'    interface aidl vendor.xiaomi.hardware.displayfeature_aidl.IDisplayFeature/default' \
		"$display_service_rc"; then
		err_print "DisplayFeature 服务 rc 缺少 AIDL interface，拒绝套用其 SELinux 片段"
		exit 1
	fi
	check_file_exists "$display_policy_fragment"
	if [[ -L "$display_policy_fragment" ]]; then
		err_print "DisplayFeature SELinux 片段不能是符号链接：$display_policy_fragment"
		exit 1
	fi
	policy_fragments+=("$display_policy_fragment")
	display_enabled=true
fi

temporary_policy_files=()
for policy_index in "${!policy_targets[@]}"; do
	policy_input="${policy_targets[$policy_index]}"
	if (( policy_index == 0 )); then
		policy_input="$effective_vendor_policy"
	fi
	temporary_policy="$(mktemp "$(get_config_path ".fix_vendor_avc_policy_${policy_index}.XXXXXX")")"
	temporary_files+=("$temporary_policy")
	merge_policy_args=(
		merge-policy
		--policy "$policy_input"
		--output "$temporary_policy"
		--api-version "$api_version"
		--replace-marker common/fix_vendor_avc
	)
	for policy_fragment in "${policy_fragments[@]}"; do
		merge_policy_args+=(--fragment "$policy_fragment")
	done
	python3 "$selinux_merger" "${merge_policy_args[@]}"
	chmod --reference="${policy_targets[$policy_index]}" -- "$temporary_policy"
	temporary_policy_files+=("$temporary_policy")
done
temporary_vendor_file_contexts="$(mktemp "$(get_config_path '.fix_vendor_avc_vendor_file_contexts.XXXXXX')")"
temporary_vendor_property_contexts="$(mktemp "$(get_config_path '.fix_vendor_avc_vendor_property_contexts.XXXXXX')")"
temporary_precompiled_file_contexts="$(mktemp "$(get_config_path '.fix_vendor_avc_precompiled_file_contexts.XXXXXX')")"
temporary_precompiled_property_contexts="$(mktemp "$(get_config_path '.fix_vendor_avc_precompiled_property_contexts.XXXXXX')")"
temporary_vendor_metadata_contexts="$(mktemp "$(get_config_path '.fix_vendor_avc_vendor_metadata_contexts.XXXXXX')")"
temporary_odm_metadata_contexts="$(mktemp "$(get_config_path '.fix_vendor_avc_odm_metadata_contexts.XXXXXX')")"
temporary_odm_metadata_fsconfig="$(mktemp "$(get_config_path '.fix_vendor_avc_odm_metadata_fsconfig.XXXXXX')")"
temporary_files+=(
	"$temporary_vendor_file_contexts"
	"$temporary_vendor_property_contexts"
	"$temporary_precompiled_file_contexts"
	"$temporary_precompiled_property_contexts"
	"$temporary_vendor_metadata_contexts"
	"$temporary_odm_metadata_contexts"
	"$temporary_odm_metadata_fsconfig"
)

python3 "$policy_patcher" \
	--policy "$effective_vendor_policy" \
	"${common_patcher_args[@]}" \
	--contexts "$effective_vendor_file_contexts" \
	--contexts-output "$temporary_vendor_file_contexts" \
	--property-contexts "$effective_vendor_property_contexts" \
	--property-contexts-output "$temporary_vendor_property_contexts"
python3 "$policy_patcher" \
	--policy "$effective_vendor_policy" \
	"${common_patcher_args[@]}" \
	--contexts "$precompiled_file_contexts" \
	--contexts-output "$temporary_precompiled_file_contexts" \
	--property-contexts "$precompiled_property_contexts" \
	--property-contexts-output "$temporary_precompiled_property_contexts"
python3 "$policy_patcher" \
	--policy "$effective_vendor_policy" \
	"${common_patcher_args[@]}" \
	--contexts "$vendor_metadata_contexts" \
	--contexts-output "$temporary_vendor_metadata_contexts" \
	--qguard-only

# ODM precompiled contexts are loaded early. Removing stale compiled policy
# files forces init to rebuild the split policy with the unified CIL block.
cp -p -- "$odm_metadata_contexts" "$temporary_odm_metadata_contexts"
cp -p -- "$odm_metadata_fsconfig" "$temporary_odm_metadata_fsconfig"
precompiled_policy_names=(
	precompiled_sepolicy
	precompiled_sepolicy.plat_and_mapping.sha256
	precompiled_sepolicy.plat_sepolicy_and_mapping.sha256
	precompiled_sepolicy.product_sepolicy_and_mapping.sha256
	precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256
	precompiled_sepolicy_debug
	precompiled_sepolicy_debug.plat_sepolicy_and_mapping.sha256
	precompiled_sepolicy_debug.product_sepolicy_and_mapping.sha256
	precompiled_sepolicy_debug.system_ext_sepolicy_and_mapping.sha256
)
for precompiled_policy_name in "${precompiled_policy_names[@]}"; do
	_partition_metadata_tool remove-prefix \
		--kind contexts \
		--target "$temporary_odm_metadata_contexts" \
		--prefix "/odm/etc/selinux/$precompiled_policy_name"
	_partition_metadata_tool remove-prefix \
		--kind fsconfig \
		--target "$temporary_odm_metadata_fsconfig" \
		--prefix "odm/etc/selinux/$precompiled_policy_name"
done
for generated_metadata in "$temporary_odm_metadata_contexts" "$temporary_odm_metadata_fsconfig"; do
	if grep -Fq 'precompiled_sepolicy' "$generated_metadata"; then
		err_print "预编译策略 metadata 清理不完整：$generated_metadata"
		exit 1
	fi
done

# Validate all generated outputs before touching the partition tree.
for policy_index in "${!policy_targets[@]}"; do
	policy_target="${policy_targets[$policy_index]}"
	policy_input="$policy_target"
	if (( policy_index == 0 )); then
		policy_input="$effective_vendor_policy"
	fi
	verify_policy="$(mktemp "$(get_config_path '.fix_vendor_avc_verify_policy.XXXXXX')")"
	temporary_files+=("$verify_policy")
	verify_args=(
		merge-policy
		--policy "$policy_input"
		--output "$verify_policy"
		--api-version "$api_version"
		--replace-marker common/fix_vendor_avc
	)
	for policy_fragment in "${policy_fragments[@]}"; do
		verify_args+=(--fragment "$policy_fragment")
	done
	python3 "$selinux_merger" "${verify_args[@]}" >/dev/null
	if ! cmp -s -- "$verify_policy" "${temporary_policy_files[$policy_index]}"; then
		err_print "统一 SELinux policy 合并不是幂等结果：$policy_target"
		exit 1
	fi
done

# Install source-vendor merge outputs first; patched policy/context outputs below
# deliberately supersede the corresponding files.
while IFS= read -r -d '' generated_file; do
	if [[ ! -f "$generated_file" || -L "$generated_file" ]]; then
		err_print "SELinux 合并生成了无效文件：$generated_file"
		exit 1
	fi
	_install_generated_file "$generated_file" "$vendor_selinux/$(basename -- "$generated_file")"
done < <(find "$vendor_merge_dir" -maxdepth 1 -type f -print0)
for policy_index in "${!policy_targets[@]}"; do
	_install_generated_file "${temporary_policy_files[$policy_index]}" "${policy_targets[$policy_index]}"
done
_install_generated_file "$temporary_vendor_file_contexts" "$vendor_file_contexts"
_install_generated_file "$temporary_vendor_property_contexts" "$vendor_property_contexts"
_install_generated_file "$temporary_precompiled_file_contexts" "$precompiled_file_contexts"
_install_generated_file "$temporary_precompiled_property_contexts" "$precompiled_property_contexts"
_install_generated_file "$temporary_vendor_metadata_contexts" "$vendor_metadata_contexts"
_install_generated_file "$temporary_odm_metadata_contexts" "$odm_metadata_contexts"
_install_generated_file "$temporary_odm_metadata_fsconfig" "$odm_metadata_fsconfig"

for precompiled_policy_name in "${precompiled_policy_names[@]}"; do
	remove_path_if_exists "$odm_selinux/$precompiled_policy_name"
done

for policy_target in "${policy_targets[@]}"; do
	python3 "$policy_patcher" \
		--policy "$policy_target" \
		"${common_patcher_args[@]}" \
		--check
done
python3 "$policy_patcher" \
	--policy "${policy_targets[0]}" \
	"${common_patcher_args[@]}" \
	--contexts "$vendor_file_contexts" \
	--check
python3 "$policy_patcher" \
	--policy "${policy_targets[0]}" \
	"${common_patcher_args[@]}" \
	--property-contexts "$vendor_property_contexts" \
	--check
python3 "$policy_patcher" \
	--policy "${policy_targets[0]}" \
	"${common_patcher_args[@]}" \
	--contexts "$precompiled_file_contexts" \
	--check
python3 "$policy_patcher" \
	--policy "${policy_targets[0]}" \
	"${common_patcher_args[@]}" \
	--property-contexts "$precompiled_property_contexts" \
	--check
python3 "$policy_patcher" \
	--policy "${policy_targets[0]}" \
	"${common_patcher_args[@]}" \
	--contexts "${vendor_metadata_contexts}" \
	--qguard-only \
	--check

if [[ "$display_enabled" == true ]]; then
	std_print "✅ 已把 DisplayFeature SELinux 片段交由统一入口合并"
else
	std_print "ℹ️ 未检测到已安装 DisplayFeature rc，跳过其 SELinux 片段"
fi
std_print "✅ 已完成 vendor 来源策略与证据规则的统一合并"
std_print "✅ 已精确重标 MI-SF/DFPS 属性并同步 vendor/ODM 早期 contexts"
std_print "✅ 已移除 stale ODM precompiled sepolicy，使开机重新合成 split CIL"
