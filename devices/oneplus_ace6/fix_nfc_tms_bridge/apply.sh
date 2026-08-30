#!/bin/bash
set -euo pipefail

# devices/oneplus_ace6/fix_nfc_tms_bridge/apply.sh
# Ace 6（青藤微系统 THN31 NFC 芯片）专属 NFC 桥接补丁，替代 NXP 专用 features/fix_nci_nfc。
# 背景：Ace 6 底包 odm 自带完整 TMS NFC HAL 栈（服务/rc/VINTF manifest/NCI 库/配置/固件），
#       而 features/fix_nci_nfc 要求底包提供 /dev/nq-nci + vendor.nxp.nxpnfc_aidl 服务契约，
#       对 Ace 6 不适用；本补丁因此替代 fix_nci_nfc 出现在 Ace 6 组合里。
# 方案：
#   1. 保留底包 odm 的 TMS 栈（随 odm 分区刷入，通过标准 android.hardware.nfc AIDL v1 提供）
#   2. 注入 ueventd 规则与 init rc 兜底：/dev/st21nfc、/dev/nq-nci → /dev/tms_nfc 符号链接
#   3. SELinux 最小放行：TMS 服务二进制复用 hal_nfc_default / hal_secure_element_default 域，
#      交付物登记为 SELinux bundle，由 common/fix_vendor_avc 统一合并
#   4. 按 NFC_PROPERTIES_FILE 写 odm/build.prop 的 ro.vendor.nfc.* 小米上层兼容开关

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "Ace 6 TMS NFC 桥接：保留底包 TMS 栈 + /dev/st21nfc 符号链接 + 最小 SELinux bundle"
std_print "来源：Ace 6 底包 odm 自带 TMS（THN31）HAL 栈；目标：原包 system + 底包 odm"
std_print

for part_name in odm vendor product system; do
	check_part_exists "$part_name"
done
check_partition_metadata_tool >/dev/null

tms_bin="$project_dir/odm/bin/hw/android.hardware.nfc-service-tms"
tms_ese_bin="$project_dir/odm/bin/hw/android.hardware.secure_element-service-tms"
tms_rc="$project_dir/odm/etc/init/nfc-service-tms.rc"
tms_manifest="$project_dir/odm/etc/vintf/manifest/manifest_nfc_thn31.xml"
tms_nci="$project_dir/odm/lib64/nfc_nci.thn31nfc.tms.so"
odm_init_dir="$project_dir/odm/etc/init"
ueventd_target="$project_dir/odm/etc/ueventd.rc"
nfc_rc_target="$project_dir/odm/etc/init/nfc_tms_symlink.rc"
odm_build_prop="$project_dir/odm/build.prop"
vendor_service_contexts="$project_dir/vendor/etc/selinux/vendor_service_contexts"
precompiled_service_contexts="$project_dir/odm/etc/selinux/precompiled_service_contexts"
nfc_perm_target="$project_dir/system/system/etc/permissions/android.hardware.nfc.xml"
odm_metadata_contexts="$(get_part_contexts_path odm)"
odm_metadata_fsconfig="$(get_part_fsconfig_path odm)"
system_metadata_contexts="$(get_part_contexts_path system)"
system_metadata_fsconfig="$(get_part_fsconfig_path system)"

selinux_bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
selinux_policy_fragment="$patcher_dir/config/selinux_policy.cil.in"
tms_file_contexts="$patcher_dir/config/nfc_tms_file_contexts"
tms_service_contexts="$patcher_dir/config/nfc_tms_service_contexts"

if [[ ! -d "$odm_init_dir" || -L "$odm_init_dir" ]]; then
	err_print "ODM init 目录不存在或不是普通目录：$odm_init_dir"
	exit 1
fi
if [[ ! -d "$(dirname -- "$nfc_perm_target")" || -L "$(dirname -- "$nfc_perm_target")" ]]; then
	err_print "system permissions 目录不存在或不是普通目录：$(dirname -- "$nfc_perm_target")"
	exit 1
fi
for required_file in \
	"$tms_bin" \
	"$tms_ese_bin" \
	"$tms_rc" \
	"$tms_manifest" \
	"$tms_nci" \
	"$odm_metadata_contexts" \
	"$odm_metadata_fsconfig" \
	"$system_metadata_contexts" \
	"$system_metadata_fsconfig" \
	"$vendor_service_contexts" \
	"$precompiled_service_contexts" \
	"$selinux_bundle_manifest" \
	"$selinux_policy_fragment" \
	"$tms_file_contexts" \
	"$tms_service_contexts"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "TMS NFC 桥接输入不能是符号链接：$required_file"
		exit 1
	fi
done

# =====================================================================
# SELinux bundle 结构自校验：与 common/fix_vendor_avc 的消费契约一致
# =====================================================================
load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"
expected_bundle_requirements=(
	odm/bin/hw/android.hardware.nfc-service-tms
	odm/bin/hw/android.hardware.secure_element-service-tms
	odm/etc/init/nfc-service-tms.rc
	odm/etc/vintf/manifest/manifest_nfc_thn31.xml
	odm/lib64/nfc_nci.thn31nfc.tms.so
)
if (( ${#SELINUX_BUNDLE_REQUIREMENTS[@]} != ${#expected_bundle_requirements[@]} ||
	${#SELINUX_BUNDLE_POLICY_FRAGMENTS[@]} != 1 ||
	${#SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]} != 4 )); then
	err_print "TMS NFC SELinux bundle 的 requirement/policy 结构不完整"
	exit 1
fi
for requirement_index in "${!expected_bundle_requirements[@]}"; do
	if [[ "${SELINUX_BUNDLE_REQUIREMENTS[$requirement_index]}" != \
		"${expected_bundle_requirements[$requirement_index]}" ]]; then
		err_print "TMS NFC SELinux bundle requirement 与 TMS 服务契约不一致"
		exit 1
	fi
done
if [[ "${SELINUX_BUNDLE_POLICY_FRAGMENTS[0]}" != \
	"$(realpath -e -- "$selinux_policy_fragment")" ]]; then
	err_print "TMS NFC SELinux bundle 没有引用模块自有策略片段"
	exit 1
fi
expected_file_fragment="$(realpath -e -- "$tms_file_contexts")"
expected_service_fragment="$(realpath -e -- "$tms_service_contexts")"
for file_context_target in vendor_file_contexts precompiled_file_contexts; do
	fragment_found=0
	for context_index in "${!SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]}"; do
		if [[ "${SELINUX_BUNDLE_CONTEXT_TARGETS[$context_index]}" == "$file_context_target" &&
			"${SELINUX_BUNDLE_CONTEXT_FRAGMENTS[$context_index]}" == "$expected_file_fragment" ]]; then
			((fragment_found += 1))
		fi
	done
	if (( fragment_found != 1 )); then
		err_print "TMS NFC SELinux bundle 缺少 $file_context_target 文件 contexts 片段"
		exit 1
	fi
done
for service_context_target in vendor_service_contexts precompiled_service_contexts; do
	fragment_found=0
	for context_index in "${!SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]}"; do
		if [[ "${SELINUX_BUNDLE_CONTEXT_TARGETS[$context_index]}" == "$service_context_target" &&
			"${SELINUX_BUNDLE_CONTEXT_FRAGMENTS[$context_index]}" == "$expected_service_fragment" ]]; then
			((fragment_found += 1))
		fi
	done
	if (( fragment_found != 1 )); then
		err_print "TMS NFC SELinux bundle 缺少 $service_context_target 服务 contexts 片段"
		exit 1
	fi
done
check_selinux_bundle_requirements "$project_dir"
if [[ "$SELINUX_BUNDLE_ACTIVE" != true ]]; then
	err_print "TMS NFC 服务未形成完整 SELinux bundle requirement"
	exit 1
fi

# =====================================================================
# 策略与 contexts 片段内容精确校验
# =====================================================================
expected_tms_policy_statements=(
	'(allow hal_nfc_default system_file (dir (read search open getattr)))'
	'(allow hal_nfc_default system_file (file (read getattr map open)))'
	'(allow hal_nfc_default vendor_data_file (dir (create read write open search getattr add_name setattr)))'
	'(allow hal_nfc_default vendor_data_file (file (create read write open getattr map setattr)))'
	'(allow hal_nfc_default vendor_data_file (filesystem (associate)))'
	'(allow nfc nfc_service (service_manager (add)))'
	'(allow nfc nfc_service (service_manager (find)))'
	'(allow nfc nfc_service (binder (call)))'
	'(allow nfc hal_nfc_service (service_manager (find)))'
	'(allow nfc hal_nfc_service (binder (call)))'
	'(allow nfc secure_element_service (service_manager (find)))'
	'(allow nfc secure_element_service (binder (call)))'
)
for expected_statement in "${expected_tms_policy_statements[@]}"; do
	if ! grep -Fqx "$expected_statement" "$selinux_policy_fragment"; then
		err_print "TMS NFC SELinux 片段缺少预期策略条目：$expected_statement"
		exit 1
	fi
done
if (( $(grep -Ec '^[[:space:]]*\(' "$selinux_policy_fragment") != ${#expected_tms_policy_statements[@]} )); then
	err_print "TMS NFC SELinux 片段包含未声明的额外策略条目"
	exit 1
fi

expected_tms_file_contexts=(
	'/odm/bin/hw/android\.hardware\.nfc-service-tms u:object_r:hal_nfc_default_exec:s0'
	'/odm/bin/hw/android\.hardware\.secure_element-service-tms u:object_r:hal_secure_element_default_exec:s0'
	'/odm/etc/nfc(/.*)? u:object_r:system_file:s0'
	'/odm/etc/vintf/manifest/manifest_nfc_thn31(_.*)?\.xml u:object_r:system_file:s0'
)
expected_tms_service_contexts=(
	'nfc_hal_service.tms.aidl u:object_r:nfc_service:s0'
	'secure_element_hal_service.aidl u:object_r:secure_element_service:s0'
)
for expected_entry in "${expected_tms_file_contexts[@]}"; do
	if ! grep -Fqx "$expected_entry" "$tms_file_contexts"; then
		err_print "TMS NFC 文件 contexts 片段缺少预期条目：$expected_entry"
		exit 1
	fi
done
if (( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$tms_file_contexts") != ${#expected_tms_file_contexts[@]} )); then
	err_print "TMS NFC 文件 contexts 片段包含未声明条目"
	exit 1
fi
for expected_entry in "${expected_tms_service_contexts[@]}"; do
	if ! grep -Fqx "$expected_entry" "$tms_service_contexts"; then
		err_print "TMS NFC 服务 contexts 片段缺少预期条目：$expected_entry"
		exit 1
	fi
done
if (( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$tms_service_contexts") != ${#expected_tms_service_contexts[@]} )); then
	err_print "TMS NFC 服务 contexts 片段包含未声明条目"
	exit 1
fi

# =====================================================================
# 临时文件与清理
# =====================================================================
temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

temporary_nfc_perm="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_perm.XXXXXX')")"
temporary_nfc_rc="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_rc.XXXXXX')")"
temporary_ueventd="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_ueventd.XXXXXX')")"
temporary_perm_contexts_patch="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_perm_ctx.XXXXXX')")"
temporary_perm_fsconfig_patch="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_perm_fs.XXXXXX')")"
temporary_system_contexts="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_sys_ctx.XXXXXX')")"
temporary_system_fsconfig="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_sys_fs.XXXXXX')")"
temporary_odm_rc_contexts_patch="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_rc_ctx.XXXXXX')")"
temporary_odm_rc_fsconfig_patch="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_rc_fs.XXXXXX')")"
temporary_odm_contexts="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_odm_ctx.XXXXXX')")"
temporary_odm_fsconfig="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_odm_fs.XXXXXX')")"
temporary_mi_nfc_patch="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_mi_nfc.XXXXXX')")"
temporary_files+=(
	"$temporary_nfc_perm"
	"$temporary_nfc_rc"
	"$temporary_ueventd"
	"$temporary_perm_contexts_patch"
	"$temporary_perm_fsconfig_patch"
	"$temporary_system_contexts"
	"$temporary_system_fsconfig"
	"$temporary_odm_rc_contexts_patch"
	"$temporary_odm_rc_fsconfig_patch"
	"$temporary_odm_contexts"
	"$temporary_odm_fsconfig"
	"$temporary_mi_nfc_patch"
)

# =====================================================================
# 1. NFC permissions XML（小米 NfcApplication 初始化前置；原包本应存在，
#    DSU 提取源不完整时兜底写入，并同步 system 分区 metadata）
# =====================================================================
perm_feature_written=0
if [[ -L "$nfc_perm_target" ]]; then
	err_print "NFC permissions 目标不能是符号链接：$nfc_perm_target"
	exit 1
elif [[ -f "$nfc_perm_target" ]] && grep -Fq 'android.hardware.nfc.any' "$nfc_perm_target"; then
	skip_print "NFC permissions 已存在"
else
	cat > "$temporary_nfc_perm" <<'EOF'
<?xml version="1.0" encoding="utf-8"?>
<!-- This is the standard feature indicating that the device can communicate
     using Near-Field Communications (NFC). -->
<permissions>
    <feature name="android.hardware.nfc" />
    <feature name="android.hardware.nfc.any" />
</permissions>
EOF
	chmod 0644 -- "$temporary_nfc_perm"
	replace_file_if_different "$temporary_nfc_perm" "$nfc_perm_target"
	if ! grep -Fq 'android.hardware.nfc.any' "$nfc_perm_target"; then
		err_print "NFC permissions 写入后校验失败：$nfc_perm_target"
		exit 1
	fi
	perm_feature_written=1
	std_print "✅ 已写入 NFC permissions: ${nfc_perm_target#"$project_dir"/}"
fi

if (( perm_feature_written == 1 )); then
	cat > "$temporary_perm_contexts_patch" <<'EOF'
/system/system/etc/permissions/android.hardware.nfc.xml u:object_r:system_file:s0
EOF
	cat > "$temporary_perm_fsconfig_patch" <<'EOF'
system/system/etc/permissions/android.hardware.nfc.xml 0 0 0644
EOF
	cp -p -- "$system_metadata_contexts" "$temporary_system_contexts"
	cp -p -- "$system_metadata_fsconfig" "$temporary_system_fsconfig"
	merge_contexts_file "$temporary_perm_contexts_patch" "$temporary_system_contexts"
	merge_fsconfig_file "$temporary_perm_fsconfig_patch" "$temporary_system_fsconfig"
	_install_generated_file "$temporary_system_contexts" "$system_metadata_contexts"
	_install_generated_file "$temporary_system_fsconfig" "$system_metadata_fsconfig"
	std_print "✅ 已同步 system 分区 metadata 的 NFC permissions 条目"
fi

# =====================================================================
# 2. init rc 兜底 symlink：/dev/st21nfc、/dev/nq-nci → /dev/tms_nfc
#    （NfcApplication 硬性检查 st21nfc 存在；新增文件同步 odm metadata）
# =====================================================================
cat > "$temporary_nfc_rc" <<'EOF'
on boot
    # Ace 6 TMS NFC 桥接兜底：确保 /dev/st21nfc 指向 /dev/tms_nfc
    symlink /dev/tms_nfc /dev/st21nfc
    symlink /dev/tms_nfc /dev/nq-nci
EOF
chmod 0644 -- "$temporary_nfc_rc"
cat > "$temporary_odm_rc_contexts_patch" <<'EOF'
/odm/etc/init/nfc_tms_symlink\.rc u:object_r:vendor_configs_file:s0
EOF
cat > "$temporary_odm_rc_fsconfig_patch" <<'EOF'
odm/etc/init/nfc_tms_symlink.rc 0 0 0644
EOF
cp -p -- "$odm_metadata_contexts" "$temporary_odm_contexts"
cp -p -- "$odm_metadata_fsconfig" "$temporary_odm_fsconfig"
merge_contexts_file "$temporary_odm_rc_contexts_patch" "$temporary_odm_contexts"
merge_fsconfig_file "$temporary_odm_rc_fsconfig_patch" "$temporary_odm_fsconfig"
if [[ -L "$nfc_rc_target" ]]; then
	err_print "TMS NFC 兜底 rc 目标不能是符号链接：$nfc_rc_target"
	exit 1
fi
replace_file_if_different "$temporary_nfc_rc" "$nfc_rc_target"
_install_generated_file "$temporary_odm_contexts" "$odm_metadata_contexts"
_install_generated_file "$temporary_odm_fsconfig" "$odm_metadata_fsconfig"
if ! grep -Fqx '    symlink /dev/tms_nfc /dev/st21nfc' "$nfc_rc_target" || \
	! grep -Fqx '/odm/etc/init/nfc_tms_symlink\.rc u:object_r:vendor_configs_file:s0' "$odm_metadata_contexts" || \
	! grep -Fqx 'odm/etc/init/nfc_tms_symlink.rc 0 0 0644' "$odm_metadata_fsconfig"; then
	err_print "TMS NFC 兜底 rc 或 odm metadata 写入后校验失败"
	exit 1
fi
std_print "✅ 已写入 init rc 兜底 symlink: ${nfc_rc_target#"$project_dir"/}"

# =====================================================================
# 3. ueventd 规则：内核创建 /dev/tms_nfc 时自动建立 ST/NXP 节点别名
#    ueventd 语法: 设备节点 mode uid gid selabel [symlink 别名 ...]
# =====================================================================
ueventd_line='/dev/tms_nfc 0660 nfc nfc u:object_r:hal_nfc_device:s0 symlink /dev/st21nfc /dev/nq-nci'
if [[ ! -e "$ueventd_target" ]]; then
	warn_print "底包 odm/etc/ueventd.rc 不存在，跳过 ueventd symlink 注入"
elif [[ ! -f "$ueventd_target" ]]; then
	err_print "odm/etc/ueventd.rc 不是普通文件：$ueventd_target"
	exit 1
elif grep -Fq 'symlink /dev/st21nfc' "$ueventd_target"; then
	skip_print "ueventd symlink 已存在"
else
	{
		cat "$ueventd_target"
		printf '\n# Ace 6 TMS NFC bridge: /dev/st21nfc -> /dev/tms_nfc\n%s\n' "$ueventd_line"
	} > "$temporary_ueventd"
	_install_generated_file "$temporary_ueventd" "$ueventd_target"
	if ! grep -Fqx "$ueventd_line" "$ueventd_target"; then
		err_print "ueventd symlink 注入后校验失败：$ueventd_target"
		exit 1
	fi
	std_print "✅ 已注入 ueventd symlink: /dev/st21nfc、/dev/nq-nci → /dev/tms_nfc"
fi

# =====================================================================
# 4. mi_nfc 服务标签兜底：小米 NfcNci（com.android.nfc）注册 "mi_nfc" 必须映射
#    nfc_service 类型。该 key 在 bundle 注册表中已由 features/fix_nci_nfc 静态持有
#    （跨 bundle contexts 键唯一），而 fix_nci_nfc 在 Ace 6 组合不激活，
#    因此由本补丁运行时按需合并；原包合并已提供时保持幂等跳过。
# =====================================================================
cat > "$temporary_mi_nfc_patch" <<'EOF'
mi_nfc u:object_r:nfc_service:s0
EOF
mi_nfc_added=0
for mi_nfc_target in "$vendor_service_contexts" "$precompiled_service_contexts"; do
	if grep -Fqx 'mi_nfc u:object_r:nfc_service:s0' "$mi_nfc_target"; then
		skip_print "mi_nfc 服务标签已存在：${mi_nfc_target#"$project_dir"/}"
	else
		merge_contexts_file "$temporary_mi_nfc_patch" "$mi_nfc_target"
		if ! grep -Fqx 'mi_nfc u:object_r:nfc_service:s0' "$mi_nfc_target"; then
			err_print "mi_nfc 服务标签合并后校验失败：$mi_nfc_target"
			exit 1
		fi
		mi_nfc_added=1
	fi
done
if (( mi_nfc_added == 1 )); then
	std_print "✅ 已补写 mi_nfc 服务标签（vendor + odm precompiled service contexts）"
fi

# =====================================================================
# 5. NFC 属性：组合入口通过 NFC_PROPERTIES_FILE 提供 ro.vendor.nfc.* 开关
# =====================================================================
prop_source="${NFC_PROPERTIES_FILE:-}"
prop_update_ready=1
if [[ -z "$prop_source" ]]; then
	warn_print "未提供目标设备 NFC 属性配置（NFC_PROPERTIES_FILE），跳过属性写入"
	prop_update_ready=0
elif [[ -L "$prop_source" ]]; then
	err_print "目标设备 NFC 属性配置不能是符号链接：$prop_source"
	exit 1
elif [[ ! -e "$prop_source" ]]; then
	warn_print "目标设备 NFC 属性配置不存在，跳过属性写入：$prop_source"
	prop_update_ready=0
elif [[ ! -f "$prop_source" ]]; then
	err_print "目标设备 NFC 属性配置不是普通文件：$prop_source"
	exit 1
fi
if [[ -L "$odm_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$odm_build_prop"
	exit 1
elif [[ ! -e "$odm_build_prop" ]]; then
	warn_print "NFC 属性目标不存在，跳过属性写入：$odm_build_prop"
	prop_update_ready=0
elif [[ ! -f "$odm_build_prop" ]]; then
	err_print "NFC 属性目标不是普通文件：$odm_build_prop"
	exit 1
fi
if (( prop_update_ready == 1 )); then
	validate_prop_file "$prop_source"
	merge_prop_file "$prop_source" "$odm_build_prop"
	prop_count="$(grep -Ec '^[[:space:]]*[^#[:space:]]' "$prop_source")"
	std_print "✅ 已写入 ${prop_count} 项 NFC 兼容属性：odm/build.prop"
fi

std_print "✅ 已登记 TMS NFC 最小 SELinux bundle，交由 common/fix_vendor_avc 统一合并"
std_print "处理完成"
