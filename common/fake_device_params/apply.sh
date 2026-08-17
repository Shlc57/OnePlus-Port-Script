#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

init_port_env "${1:-}"

std_print "写入 Settings 设备参数伪装缓存"
std_print "使用专用 fake_device_params SELinux 域，不依赖任何 root 管理器域"
std_print "只影响 com.android.settings 的设备信息显示，不修改任何 prop"
std_print

check_part_exists system
check_partition_metadata_tool >/dev/null

if [[ -z "${DEVICE_PARAMS_SPOOF_JSON:-}" ]]; then
	err_print "请通过 DEVICE_PARAMS_SPOOF_JSON 传入完整 JSON 参数"
	exit 1
fi

generator="$patcher_dir/generate_device_params.py"
runtime_script="$patcher_dir/fake_device_params.sh"
policy_fragment="$patcher_dir/fake_device_params.cil"
policy_patcher="$patcher_dir/patch_device_params_policy.py"
for patch_file in "$generator" "$runtime_script" "$policy_fragment" "$policy_patcher"; do
	check_file_exists "$patch_file"
	if [[ -L "$patch_file" ]]; then
		err_print "设备参数伪装补丁文件不能是符号链接：$patch_file"
		exit 1
	fi
done

# project_dir is exported by init_port_env in tools.sh.
# shellcheck disable=SC2154
system_root="$project_dir/system/system"
system_etc="$system_root/etc"
system_init="$system_etc/init"
system_selinux="$system_etc/selinux"
system_metadata_contexts="$(get_part_contexts_path system)"
system_metadata_fsconfig="$(get_part_fsconfig_path system)"
plat_file_contexts="$system_selinux/plat_file_contexts"
plat_policy="$system_selinux/plat_sepolicy.cil"
plat_policy_hash="$system_selinux/plat_sepolicy_and_mapping.sha256"
system_ext_root="$project_dir/system_ext"
system_ext_etc="$system_ext_root/etc"
system_ext_selinux="$system_ext_etc/selinux"
userdebug_plat_policy="$system_ext_selinux/userdebug_plat_sepolicy.cil"

for required_dir in "$system_root" "$system_etc" "$system_init" "$system_selinux"; do
	if [[ ! -d "$required_dir" || -L "$required_dir" ]]; then
		err_print "system 目标目录不存在或不是普通目录：$required_dir"
		exit 1
	fi
done
for required_file in \
	"$system_metadata_contexts" \
	"$system_metadata_fsconfig" \
	"$plat_file_contexts" \
	"$plat_policy" \
	"$plat_policy_hash"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "system 目标文件不能是符号链接：$required_file"
		exit 1
	fi
done

policy_targets=("$plat_policy")
policy_target_labels=(plat_sepolicy)
if [[ -e "$userdebug_plat_policy" || -L "$userdebug_plat_policy" ]]; then
	for userdebug_parent in "$system_ext_root" "$system_ext_etc" "$system_ext_selinux"; do
		if [[ ! -d "$userdebug_parent" || -L "$userdebug_parent" ]]; then
			err_print "userdebug plat policy 父目录不存在或不是普通目录：$userdebug_parent"
			exit 1
		fi
	done
	check_file_exists "$userdebug_plat_policy"
	if [[ ! -f "$userdebug_plat_policy" || -L "$userdebug_plat_policy" ]]; then
		err_print "userdebug plat policy 不是普通文件：$userdebug_plat_policy"
		exit 1
	fi
	policy_targets+=("$userdebug_plat_policy")
	policy_target_labels+=(userdebug_plat_sepolicy)
fi

read -r current_policy_hash extra_hash_field < "$plat_policy_hash" || true
if [[ ! "${current_policy_hash:-}" =~ ^[0-9a-fA-F]{64}$ || -n "${extra_hash_field:-}" ]]; then
	err_print "plat policy hash 标记格式无效：$plat_policy_hash"
	exit 1
fi

device_params_dir="$system_etc/device_params"
device_params_xml="$device_params_dir/device_params_pref.xml"
device_params_script="$device_params_dir/fake_device_params.sh"
device_params_rc="$system_init/fake_device_params.rc"
for target_path in "$device_params_dir" "$device_params_xml" "$device_params_script" "$device_params_rc"; do
	if [[ -L "$target_path" ]]; then
		err_print "目标路径不能是符号链接：$target_path"
		exit 1
	fi
done
if [[ -e "$device_params_dir" && ! -d "$device_params_dir" ]]; then
	err_print "设备参数目标目录不是普通目录：$device_params_dir"
	exit 1
fi
for target_file in "$device_params_xml" "$device_params_script" "$device_params_rc"; do
	if [[ -e "$target_file" && ! -f "$target_file" ]]; then
		err_print "设备参数目标不是普通文件：$target_file"
		exit 1
	fi
done

temporary_files=()
cleanup() {
	local temporary_file
	for temporary_file in "${temporary_files[@]}"; do
		rm -f -- "$temporary_file"
	done
}
trap cleanup EXIT

temporary_xml="$(mktemp "$(get_config_path '.device_params_pref.xml.XXXXXX')")"
temporary_files+=("$temporary_xml")
if ! DEVICE_PARAMS_SPOOF_JSON="$DEVICE_PARAMS_SPOOF_JSON" python3 "$generator" \
	--output "$temporary_xml"; then
	err_print "DEVICE_PARAMS_SPOOF_JSON 校验或 XML 生成失败"
	exit 1
fi
chmod 0644 -- "$temporary_xml"

temporary_rc="$(mktemp "$(get_config_path '.fake_device_params.rc.XXXXXX')")"
temporary_files+=("$temporary_rc")
cat > "$temporary_rc" <<'EOF'
service fake_device_params /system/etc/device_params/fake_device_params.sh
    class late_start
    user system
    group system
    disabled
    oneshot

on property:sys.boot_completed=1
    start fake_device_params
EOF
chmod 0644 -- "$temporary_rc"

temporary_contexts_patch="$(mktemp "$(get_config_path '.fake_device_params_contexts.XXXXXX')")"
temporary_files+=("$temporary_contexts_patch")
cat > "$temporary_contexts_patch" <<'EOF'
/system/system/etc/device_params u:object_r:system_file:s0
/system/system/etc/device_params/device_params_pref\.xml u:object_r:system_file:s0
/system/system/etc/device_params/fake_device_params\.sh u:object_r:fake_device_params_exec:s0
/system/system/etc/init/fake_device_params\.rc u:object_r:system_file:s0
EOF

temporary_fsconfig_patch="$(mktemp "$(get_config_path '.fake_device_params_fsconfig.XXXXXX')")"
temporary_files+=("$temporary_fsconfig_patch")
cat > "$temporary_fsconfig_patch" <<'EOF'
system/system/etc/device_params 0 0 0755
system/system/etc/device_params/device_params_pref.xml 0 0 0644
system/system/etc/device_params/fake_device_params.sh 0 0 0755
system/system/etc/init/fake_device_params.rc 0 0 0644
EOF

temporary_runtime_contexts_patch="$(mktemp "$(get_config_path '.fake_device_params_plat_contexts.XXXXXX')")"
temporary_files+=("$temporary_runtime_contexts_patch")
cat > "$temporary_runtime_contexts_patch" <<'EOF'
/system/etc/device_params/fake_device_params\.sh u:object_r:fake_device_params_exec:s0
EOF

# Prepare and validate every generated policy/metadata file before modifying
# the real unpacked partition tree.
temporary_contexts="$(mktemp "$(get_config_path '.fake_device_params_system_contexts.XXXXXX')")"
temporary_files+=("$temporary_contexts")
temporary_fsconfig="$(mktemp "$(get_config_path '.fake_device_params_system_fsconfig.XXXXXX')")"
temporary_files+=("$temporary_fsconfig")
temporary_plat_file_contexts="$(mktemp "$(get_config_path '.fake_device_params_plat_file_contexts.XXXXXX')")"
temporary_files+=("$temporary_plat_file_contexts")
temporary_plat_policy_hash="$(mktemp "$(get_config_path '.fake_device_params_plat_policy_hash.XXXXXX')")"
temporary_files+=("$temporary_plat_policy_hash")

cp -p -- "$system_metadata_contexts" "$temporary_contexts"
cp -p -- "$system_metadata_fsconfig" "$temporary_fsconfig"
cp -p -- "$plat_file_contexts" "$temporary_plat_file_contexts"
cp -p -- "$plat_policy_hash" "$temporary_plat_policy_hash"

merge_contexts_file "$temporary_contexts_patch" "$temporary_contexts"
merge_fsconfig_file "$temporary_fsconfig_patch" "$temporary_fsconfig"
merge_contexts_file "$temporary_runtime_contexts_patch" "$temporary_plat_file_contexts"

temporary_policy_files=()
for policy_index in "${!policy_targets[@]}"; do
	temporary_policy="$(mktemp "$(get_config_path ".fake_device_params_policy_${policy_index}.XXXXXX")")"
	temporary_files+=("$temporary_policy")
	temporary_policy_files+=("$temporary_policy")
	python3 "$policy_patcher" \
		--policy "${policy_targets[$policy_index]}" \
		--fragment "$policy_fragment" \
		--output "$temporary_policy"
	chmod --reference="${policy_targets[$policy_index]}" -- "$temporary_policy"
done

{
	printf 'fake_device_params\n'
	for policy_index in "${!temporary_policy_files[@]}"; do
		policy_digest="$(sha256sum "${temporary_policy_files[$policy_index]}" | awk 'NR == 1 { print $1 }')"
		printf '%s:%s\n' "${policy_target_labels[$policy_index]}" "$policy_digest"
	done
} | sha256sum | awk 'NR == 1 { print $1 }' > "$temporary_plat_policy_hash"
if ! grep -Eq '^[0-9a-f]{64}$' "$temporary_plat_policy_hash"; then
	err_print "生成的 plat policy hash 标记无效"
	exit 1
fi
expected_policy_hash="$(tr -d '\n' < "$temporary_plat_policy_hash")"

precompiled_hash_candidates=(
	"$project_dir/odm/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256"
	"$project_dir/odm/etc/selinux/precompiled_sepolicy_debug.plat_sepolicy_and_mapping.sha256"
	"$project_dir/vendor/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256"
	"$project_dir/vendor/etc/selinux/precompiled_sepolicy_debug.plat_sepolicy_and_mapping.sha256"
)
for precompiled_hash in "${precompiled_hash_candidates[@]}"; do
	if [[ -f "$precompiled_hash" ]] && cmp -s "$temporary_plat_policy_hash" "$precompiled_hash"; then
		err_print "新的 system policy hash 意外匹配旧 precompiled policy：$precompiled_hash"
		exit 1
	fi
done

std_print "init 将以 system UID 启动专用 fake_device_params 域"

mkdir -p -- "$device_params_dir"
chmod 0755 -- "$device_params_dir"
replace_file_if_different "$temporary_xml" "$device_params_xml"
replace_file_if_different "$runtime_script" "$device_params_script"
replace_file_if_different "$temporary_rc" "$device_params_rc"

chmod 0755 -- "$device_params_dir" "$device_params_script"
chmod 0644 -- "$device_params_xml" "$device_params_rc"
_install_generated_file "$temporary_plat_file_contexts" "$plat_file_contexts"
for policy_index in "${!policy_targets[@]}"; do
	_install_generated_file \
		"${temporary_policy_files[$policy_index]}" \
		"${policy_targets[$policy_index]}"
done
_install_generated_file "$temporary_plat_policy_hash" "$plat_policy_hash"
_install_generated_file "$temporary_contexts" "$system_metadata_contexts"
_install_generated_file "$temporary_fsconfig" "$system_metadata_fsconfig"

for policy_target in "${policy_targets[@]}"; do
	python3 "$policy_patcher" \
		--policy "$policy_target" \
		--fragment "$policy_fragment" \
		--check
done
if ! grep -Fqx '/system/system/etc/device_params u:object_r:system_file:s0' "$system_metadata_contexts" || \
	! grep -Fqx '/system/system/etc/device_params/device_params_pref\.xml u:object_r:system_file:s0' "$system_metadata_contexts" || \
	! grep -Fqx '/system/system/etc/device_params/fake_device_params\.sh u:object_r:fake_device_params_exec:s0' "$system_metadata_contexts" || \
	! grep -Fqx '/system/system/etc/init/fake_device_params\.rc u:object_r:system_file:s0' "$system_metadata_contexts" || \
	! grep -Fqx 'system/system/etc/device_params 0 0 0755' "$system_metadata_fsconfig" || \
	! grep -Fqx 'system/system/etc/device_params/device_params_pref.xml 0 0 0644' "$system_metadata_fsconfig" || \
	! grep -Fqx 'system/system/etc/device_params/fake_device_params.sh 0 0 0755' "$system_metadata_fsconfig" || \
	! grep -Fqx 'system/system/etc/init/fake_device_params.rc 0 0 0644' "$system_metadata_fsconfig" || \
	! grep -Fqx '/system/etc/device_params/fake_device_params\.sh u:object_r:fake_device_params_exec:s0' "$plat_file_contexts" || \
	! grep -Fqx 'service fake_device_params /system/etc/device_params/fake_device_params.sh' "$device_params_rc" || \
	! grep -Fqx '    user system' "$device_params_rc" || \
	! grep -Fqx '    group system' "$device_params_rc" || \
	! grep -Fqx "$expected_policy_hash" "$plat_policy_hash"; then
	err_print "设备参数专用域、metadata 或 init 服务写入后校验失败"
	exit 1
fi
if grep -Eq 'magisk|ksu|u:r:su:s0|seclabel' "$device_params_rc"; then
	err_print "设备参数 init 服务仍残留固定 root 域依赖"
	exit 1
fi

std_print "✅ 已生成 Settings 设备参数缓存与专用 init 服务"
std_print "✅ 已写入 fake_device_params 域、exec context 和最小应用数据权限"
std_print "✅ 已更新 policy hash 标记，确保旧 precompiled policy 不会覆盖新规则"
std_print "重启后由 system UID 的专用域写入 user 0 缓存；当前补丁不修改任何 prop"
std_print "处理完成"
