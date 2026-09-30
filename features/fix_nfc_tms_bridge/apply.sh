#!/bin/bash
set -euo pipefail

# features/fix_nfc_tms_bridge/apply.sh
# 青藤微系统 THN31（TMS 栈）NFC 桥接补丁，供底包自带 TMS NFC 栈的机型共用（当前：一加 Ace 6、真我 Neo8）。
# 适用条件：底包 odm 自带 android.hardware.nfc-service-tms + manifest_nfc_thn31.xml + /dev/tms_nfc。
# 背景：这些机型的小米 HyperOS 移植侧 NFC 是 MIUI 签名的 com.android.nfc（Nfc_st，自带 NCI 栈），
#       而 features/fix_nci_nfc 要求底包提供 /dev/nq-nci + vendor.nxp.nxpnfc_aidl NXP 服务契约，
#       对 TMS 机型不适用；本补丁因此替代 fix_nci_nfc 出现在 TMS 机型组合里。
# 方案：
#   1. 保留底包 odm 的 TMS 栈（随 odm 分区刷入，通过标准 android.hardware.nfc AIDL v1 提供）
#   2. 注入 ueventd 规则与 init rc 兜底：/dev/st21nfc、/dev/nq-nci → /dev/tms_nfc 符号链接
#   3. SELinux 最小放行：TMS 服务二进制复用 hal_nfc_default / hal_secure_element_default 域，
#      交付物登记为 SELinux bundle，由 common/fix_vendor_avc 统一合并
#   4. 按 NFC_PROPERTIES_FILE 写 odm/build.prop 的 ro.vendor.nfc.* 小米上层兼容开关

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "THN31/TMS NFC 桥接：保留底包 TMS 栈 + /dev/st21nfc 符号链接 + 最小 SELinux bundle"
std_print "来源：底包 odm 自带 TMS（THN31）HAL 栈；目标：原包 system + 底包 odm"
std_print

for part_name in odm vendor product system; do
	check_part_exists "$part_name"
done
check_partition_metadata_tool >/dev/null

# project_dir 由 tools.sh 的 init_port_env 注入。
# shellcheck disable=SC2154
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
vendor_property_contexts="$project_dir/vendor/etc/selinux/vendor_property_contexts"
precompiled_property_contexts="$project_dir/odm/etc/selinux/precompiled_property_contexts"
nfc_perm_target="$project_dir/system/system/etc/permissions/android.hardware.nfc.xml"
odm_metadata_contexts="$(get_part_contexts_path odm)"
odm_metadata_fsconfig="$(get_part_fsconfig_path odm)"
system_metadata_contexts="$(get_part_contexts_path system)"
system_metadata_fsconfig="$(get_part_fsconfig_path system)"

selinux_bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
selinux_policy_fragment="$patcher_dir/config/selinux_policy.cil.in"
tms_file_contexts="$patcher_dir/config/nfc_tms_file_contexts"
tms_service_contexts="$patcher_dir/config/nfc_tms_service_contexts"
tms_property_contexts="$patcher_dir/config/nfc_tms_property_contexts"

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
	"$vendor_property_contexts" \
	"$precompiled_property_contexts" \
	"$selinux_bundle_manifest" \
	"$selinux_policy_fragment" \
	"$tms_file_contexts" \
	"$tms_service_contexts" \
	"$tms_property_contexts"; do
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
	'(allow nfc vendor_tms_nfc_prop (file (read getattr map open)))'
	'(allow vendor_init system_file (file (read getattr map open)))'
	'(allow vendor_init vendor_data_file (dir (create read write open search getattr add_name setattr)))'
	'(allow vendor_init vendor_data_file (file (create read write open getattr setattr unlink rename)))'
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
	'/odm/etc/libnfc-tms(_RF_[A-Z0-9]+)?\.conf u:object_r:system_file:s0'
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
expected_tms_property_contexts=(
	'ro.vendor.nfc. u:object_r:vendor_tms_nfc_prop:s0'
)
for expected_entry in "${expected_tms_property_contexts[@]}"; do
	if ! grep -Fqx "$expected_entry" "$tms_property_contexts"; then
		err_print "TMS NFC 属性 contexts 片段缺少预期条目：$expected_entry"
		exit 1
	fi
done
if (( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$tms_property_contexts") != ${#expected_tms_property_contexts[@]} )); then
	err_print "TMS NFC 属性 contexts 片段包含未声明条目"
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
temporary_nfc_prop_label="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_nfc_prop_label.XXXXXX')")"
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
# 2. init rc 兜底 symlink：/dev/thn31、/dev/st21nfc、/dev/nq-nci → /dev/tms_nfc
#    /dev/thn31 是硬需求：TMS NCI 库在拿不到 libnfc-tms.conf 里的 TMS_NFC_DEV_NODE 时，
#    会回退到它自己的默认节点 /dev/thn31（库内串：“Invalid nfc device node name keeping the
#    default device node /dev/thn31”），而底包 ueventd/init 不创建它 ⇒ 控制器根开不了。
#    st21nfc/nq-nci 两个别名保留（小米侧框架与非小米 HAL 的历史命名），新增文件同步 odm metadata。
# =====================================================================
cat > "$temporary_nfc_rc" <<'EOF'
on boot
    # TMS NFC 桥接兜底：HAL 默认节点与 ST/NXP 命名别名都指向 /dev/tms_nfc
    symlink /dev/tms_nfc /dev/thn31
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
if ! grep -Fqx '    symlink /dev/tms_nfc /dev/thn31' "$nfc_rc_target" || \
	! grep -Fqx '    symlink /dev/tms_nfc /dev/st21nfc' "$nfc_rc_target" || \
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
ueventd_line='/dev/tms_nfc 0660 nfc nfc u:object_r:hal_nfc_device:s0 symlink /dev/thn31 /dev/st21nfc /dev/nq-nci'
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
		printf '\n# TMS NFC bridge: /dev/st21nfc -> /dev/tms_nfc\n%s\n' "$ueventd_line"
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

# =====================================================================
# 6. 让 TMS HAL 独占 android.hardware.nfc/INfc/default
#    底包 vendor 可能同时存着按其它芯片实现的 NFC HAL（ST/NXP），且其 init rc 会声明
#    `interface aidl android.hardware.nfc.INfc/default`。原厂 ColorOS framework 走 Oplus
#    私有 NFC 接口所以不受影响；但 HyperOS 的 com.android.nfc 走标准 INfc，会连到
#    先注册该名的 HAL。叠上本补丁建立的 /dev/st21nfc→/dev/tms_nfc 别名后，竞争 HAL 不再
#    因找不到芯片节点而退出，于是把 ST 专有命令发到 TMS 控制器（真机硬证据：
#    `nfaVSCallback: RSP status: 8 to Android proprietary cmd 9`、startRfDiscovery 完成超时、
#    nfc_ncif_cmd_timeout → NFA_DM_NFCC_TIMEOUT_EVT → recovery nfc、RF_INTF_ACTIVATED=0，
#    且 ST 与 TMS 两个 HAL 进程同时存活）。对照：一加 Ace6 底包只有 TMS HAL（无竞争者），
#    一加 Ace6T 走 NXP 节点真实存在且不建 ST 别名，所以只在本模块遇到“多个 INfc 提供者”时处理。
#    动作（均为 rc 内容修改，不改路径/属主/权限，不动 contexts/fsconfig）：
#      a) 删掉非目标厂商 NFC HAL rc 里的 `interface aidl android.hardware.nfc.INfc/default` 声明，
#         并给该 service 补 `disabled`。两者必须成对：只加 disabled 而保留 interface 声明的话，
#         init 会把它当作 lazy HAL，servicemanager 一旦收到该名字请求就会把它拉起来。
#      b) 仅当 a) 真的禁用了竞争者时，才在 odm rc 里显式声明 TMS 的 INfc 注册，
#         保证禁用后仍有一个合法提供者。底包本来无竞争者（如一加 Ace6）时不动 TMS rc，
#         避免给已可用的机型引入回归。
#    底包没有竞争 HAL 时 a)、b) 都跳过（一加 Ace6 就是这个情况）。
# =====================================================================
vendor_etc_init_dir="$project_dir/vendor/etc/init"
competing_hal_rc=()
while IFS= read -r -d '' candidate_rc; do
	[[ "$candidate_rc" == "$tms_rc" ]] && continue
	if grep -Eq "^service[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+.*(android\.hardware\.nfc-service-[^[:space:]]*)" "$candidate_rc" &&
		! grep -Eq "^service[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+.*android\.hardware\.nfc-service-tms" "$candidate_rc"; then
		competing_hal_rc+=("$candidate_rc")
	fi
done < <(find "$vendor_etc_init_dir" "$odm_init_dir" -maxdepth 1 -type f -name '*.rc' -print0 2>/dev/null | sort -z)

if (( ${#competing_hal_rc[@]} == 0 )); then
	skip_print "底包没有与 TMS 争 INfc/default 的其他厂商 NFC HAL，跳过禁用步骤"
else
	hal_rc_fixed=0
	for rc_target in "${competing_hal_rc[@]}"; do
		if [[ -L "$rc_target" ]]; then
			err_print "不支持修改符号链接的 NFC HAL rc：$rc_target"
			exit 1
		fi
		temporary_nfc_hal_rc="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_halrc.XXXXXX')")"
		temporary_files+=("$temporary_nfc_hal_rc")
		# 单遍 awk：先缓存全文，再逐行判定是否处于非目标厂商 NFC HAL 的 service 块内；
		# 块内丢弃 INfc/default 接口声明行，并在块头后补一行 disabled（已有则不重复）。
		# 注意END 块里不能用 next，故用 continue；接口声明行本身不是 service 头，
		# 所以靠 inblk 状态而不是逐行正则判定。
		if ! awk '
			{ buf[NR] = $0 }
			END {
				inblk = 0
				hdr = 0
				have = 0
				for (i = 1; i <= NR; i++) {
					line = buf[i]
					is_hdr = (line ~ /^[[:space:]]*service[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+/)
					is_on = (line ~ /^[[:space:]]*on[[:space:]]/)
					is_comp = (is_hdr && line ~ /android\.hardware\.nfc-service-/ && line !~ /android\.hardware\.nfc-service-tms/)
					if (is_comp) {
						inblk = 1
						hdr = i
						have = 0
						for (j = i + 1; j <= NR; j++) {
							if (buf[j] ~ /^[[:space:]]*service[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+/ ||
								buf[j] ~ /^[[:space:]]*on[[:space:]]/) { break }
							if (buf[j] ~ /^[[:space:]]+disabled[[:space:]]*$/) { have = 1 }
						}
					} else if (is_hdr || is_on) {
						inblk = 0
					}
					if (inblk && line ~ /android\.hardware\.nfc\.INfc\/default/) { continue }
					print line
					if (inblk && i == hdr && have == 0) { print "    disabled" }
				}
			}
		' "$rc_target" > "$temporary_nfc_hal_rc"; then
			err_print "禁用竞争 NFC HAL 服务失败：${rc_target#"$project_dir"/}"
			exit 1
		fi
		if ! grep -Eq '^[[:space:]]+disabled[[:space:]]*$' "$temporary_nfc_hal_rc"; then
			err_print "竞争 NFC HAL rc 改写后未出现 disabled 行：${rc_target#"$project_dir"/}"
			exit 1
		fi
		if grep -Fq 'interface aidl android.hardware.nfc.INfc/default' "$temporary_nfc_hal_rc"; then
			err_print "竞争 NFC HAL rc 改写后仍声明 INfc/default（会被当作 lazy HAL 按需拉起）：${rc_target#"$project_dir"/}"
			exit 1
		fi
		if cmp -s -- "$temporary_nfc_hal_rc" "$rc_target"; then
			skip_print "竞争 NFC HAL 已标记 disabled：${rc_target#"$project_dir"/}"
		elif ! replace_file_if_different "$temporary_nfc_hal_rc" "$rc_target"; then
			err_print "写回竞争 NFC HAL rc 失败：${rc_target#"$project_dir"/}"
			exit 1
		else
			std_print "✅ 已禁用非目标厂商 NFC HAL：${rc_target#"$project_dir"/}"
			hal_rc_fixed=1
		fi
		rm -f -- "$temporary_nfc_hal_rc"
	done
	if (( hal_rc_fixed == 0 )); then
		skip_print "所有竞争 NFC HAL 已处于 disabled 形态"
	fi
fi

# TMS 服务的 INfc 注册显式化：仅在确实禁用了竞争者时才做。底包只靠二进制 addService，
# 而 odm VINTF 已声明该接口；在 rc 里补上 interface 行后，init/servicemanager 能确定地
# 把它当作 INfc/default 提供者。无竞争者的机型（Ace6）保持底包原样，不新增风险。
if (( ${#competing_hal_rc[@]} == 0 )); then
	skip_print "底包无竞争 NFC HAL，不动 TMS 服务的接口声明"
elif grep -Fqx '    interface aidl android.hardware.nfc.INfc/default' "$tms_rc"; then
	skip_print "TMS NFC rc 已声明 android.hardware.nfc.INfc/default"
else
	temporary_tms_iface_rc="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_tmsiface.XXXXXX')")"
	temporary_files+=("$temporary_tms_iface_rc")
	if ! awk '
		{
			print
			if ($0 ~ /^[[:space:]]*service[[:space:]]+[A-Za-z0-9_.-]+[[:space:]]+.*android\.hardware\.nfc-service-tms/) {
				print "    interface aidl android.hardware.nfc.INfc/default"
			}
		}
	' "$tms_rc" > "$temporary_tms_iface_rc"; then
		err_print "为 TMS NFC 服务声明 INfc 接口失败"
		exit 1
	fi
	if [[ $(grep -Fc 'interface aidl android.hardware.nfc.INfc/default' "$temporary_tms_iface_rc") != "1" ]]; then
		err_print "TMS NFC rc 改写后缺少唯一的 INfc 接口声明"
		exit 1
	fi
	if ! replace_file_if_different "$temporary_tms_iface_rc" "$tms_rc"; then
		err_print "写回 TMS NFC rc 失败：${tms_rc#"$project_dir"/}"
		exit 1
	fi
	rm -f -- "$temporary_tms_iface_rc"
	std_print "✅ 已在 TMS NFC 服务声明 interface aidl android.hardware.nfc.INfc/default"
fi

std_print "✅ 已登记 TMS NFC 最小 SELinux bundle，交由 common/fix_vendor_avc 统一合并"

# =====================================================================
# 7. ro.vendor.nfc.* 的属性标签：运行时幂等合并，不进 bundle 注册表
#    同一个键已由 fix_nci_nfc 静态持有（跨 bundle 的 contexts 键归属必须全局唯一，
#    否则 common/fix_vendor_avc 会在运行时报冲突），所以沿用上面 mi_nfc 的先例：
#    本模块在运行时按需合并并幂等跳过。类型用底包已有的 vendor_tms_nfc_prop
#    （fix_nci_nfc 用的是小米侧 vendor_nfc_mi_prop，两条路线不会在同一设备共存）。
# =====================================================================
prop_label_entry='ro.vendor.nfc. u:object_r:vendor_tms_nfc_prop:s0'
# 以 config/nfc_tms_property_contexts 为单一事实源（上面已校验它只含这一条有效条目）。
file_label_entry="$(grep -Ev '^[[:space:]]*(#|$)' "$tms_property_contexts" | head -n 1)"
if [[ "$file_label_entry" != "$prop_label_entry" ]]; then
	err_print "nfc_tms_property_contexts 与预期标签不一致：${file_label_entry:-<空>}"
	exit 1
fi
prop_label_added=0
for prop_label_target in "$vendor_property_contexts" "$precompiled_property_contexts"; do
	if grep -Fqx "$prop_label_entry" "$prop_label_target"; then
		skip_print "ro.vendor.nfc. 属性标签已存在：${prop_label_target#"$project_dir"/}"
	elif ! grep -Eq '^[[:space:]]*ro\.vendor\.nfc\.' "$prop_label_target"; then
		printf '%s\n' "$prop_label_entry" > "$temporary_nfc_prop_label"
		merge_contexts_file "$temporary_nfc_prop_label" "$prop_label_target"
		if ! grep -Fqx "$prop_label_entry" "$prop_label_target"; then
			err_print "ro.vendor.nfc. 属性标签合并后校验失败：$prop_label_target"
			exit 1
		fi
		prop_label_added=1
	else
		err_print "$prop_label_target 已有其它 ro.vendor.nfc. 标签，拒绝静默覆盖"
		exit 1
	fi
done
if (( prop_label_added == 1 )); then
	std_print "✅ 已补写 ro.vendor.nfc. 属性标签（vendor + odm precompiled property contexts）"
fi

# =====================================================================
# 8. 播种 TMS NCI 运行配置（两台共同根因的直接修法）
#    TMS 的 NCI 实现库只认固定文件名：HAL 候选路径是 /data/vendor/nfc/、/odm/etc/ 与
#    /vendor/etc/libnfc-tms.conf；读不到就用内置默认（默认节点 /dev/thn31、无 NFCEE 电源链路
#    与 VS 专有配置）。底包只带 odm/etc/nfc/<name>_<project>，realme 原厂由 system 侧 Oplus
#    NfcNci 应用用 copyFile 铺成运行名（其 dex 里 /data/vendor/nfc 命中 29、_RF_ 命中 62），
#    移植侧没有那个上层（也不能把它的 apk 装进来：同包名同 android.uid.nfc，签名互斥）。
#    本步骤用两个零猜测的补位：
#      a) 打包期把 <name>_<prjname> 复制成 /odm/etc/<name> 裸名（HAL 搜索目录之一）；
#      b) 新增 init rc，在 post-fs-data 把裸名铺到 /data/vendor/nfc/（HAL 首选路径）。
#    prjname 从 odm/build.prop 的 ro.separate.soft 探测，退到 odm/etc/fingerprint.json 的 project；
#    都拿不到只警告并跳过本步骤（补丁不写死任何机型代号）。默认只铺基础通路必需的
#    libnfc-tms* ；入口设 NFC_TMS_SEED_ALL_CONFIGS=1 时连门禁/城市/SuperCard 配置一起铺。
#    注：conf 内容逐字照抄底包（含 NFA_STORAGE="/data/nfc"）；若回传出现 hal_nfc_default 对
#    nfc_data_file 的拒绝，再评估改写，不提前偏离原厂行为。
# =====================================================================
odm_nfc_dir="$project_dir/odm/etc/nfc"
tms_prjname="$(read_prop_value ro.separate.soft "$odm_build_prop" 2>/dev/null)" || tms_prjname=''
if [[ ! "$tms_prjname" =~ ^[0-9]+$ && -r "$project_dir/odm/etc/fingerprint.json" ]]; then
	tms_prjname="$(tr -d '\n\r' < "$project_dir/odm/etc/fingerprint.json" \
		| grep -o -E '"project":"[0-9]+"' | head -n 1 | grep -o -E '[0-9]+')" || tms_prjname=''
fi
declare -a seed_names=()
if [[ ! "$tms_prjname" =~ ^[0-9]+$ ]]; then
	warn_print "探测不到 ODM project id（ro.separate.soft 与 fingerprint.json 都无），跳过 TMS 配置播种"
elif [[ ! -d "$odm_nfc_dir" ]]; then
	warn_print "底包没有 odm/etc/nfc 目录，跳过 TMS 配置播种"
else
	while IFS= read -r -d '' seed_src; do
		seed_base="$(basename -- "$seed_src")"
		seed_name="${seed_base%_${tms_prjname}}"
		if [[ "${NFC_TMS_SEED_ALL_CONFIGS:-0}" != 1 && "$seed_name" != libnfc-tms* ]]; then
			continue
		fi
		seed_names+=("$seed_name")
	done < <(find "$odm_nfc_dir" -maxdepth 1 -type f -name "*_${tms_prjname}" -print0 2>/dev/null | sort -z)
	if (( ${#seed_names[@]} == 0 )); then
		skip_print "odm/etc/nfc 下没找到可播种的 *_${tms_prjname} 配置（project id 可能不是 NFC 用途）"
	fi
fi

if (( ${#seed_names[@]} > 0 )); then
	temporary_seed_rc="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_seed_rc.XXXXXX')")"
	temporary_seed_ctx="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_seed_ctx.XXXXXX')")"
	temporary_seed_fs="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_seed_fs.XXXXXX')")"
	temporary_seed_file="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_seed_file.XXXXXX')")"
	temporary_seed_odm_ctx="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_seed_odm_ctx.XXXXXX')")"
	temporary_seed_odm_fs="$(mktemp "$(get_config_path '.fix_nfc_tms_bridge_seed_odm_fs.XXXXXX')")"
	temporary_files+=(
		"$temporary_seed_rc" "$temporary_seed_ctx" "$temporary_seed_fs" "$temporary_seed_file"
		"$temporary_seed_odm_ctx" "$temporary_seed_odm_fs"
	)
	tms_seed_rc_target="$odm_init_dir/nfc_tms_seed_config.rc"
	if [[ -L "$tms_seed_rc_target" ]]; then
		err_print "TMS 配置播种 rc 目标不能是符号链接：$tms_seed_rc_target"
		exit 1
	fi

	printf '/odm/etc/init/nfc_tms_seed_config\.rc u:object_r:vendor_configs_file:s0\n' > "$temporary_seed_ctx"
	printf 'odm/etc/init/nfc_tms_seed_config.rc 0 0 0644\n' > "$temporary_seed_fs"
	{
		printf 'on post-fs-data\n'
		printf '    mkdir /data/vendor/nfc 0777 nfc nfc\n'
	} > "$temporary_seed_rc"

	for seed_name in "${seed_names[@]}"; do
		seed_src="$odm_nfc_dir/${seed_name}_${tms_prjname}"
		seed_dst="$project_dir/odm/etc/$seed_name"
		if [[ -L "$seed_dst" ]]; then
			err_print "TMS 配置裸名目标不能是符号链接：$seed_dst"
			exit 1
		fi
		seed_esc="${seed_name//./\\.}"
		printf '/odm/etc/%s u:object_r:system_file:s0\n' "$seed_esc" >> "$temporary_seed_ctx"
		printf 'odm/etc/%s 0 0 0644\n' "$seed_name" >> "$temporary_seed_fs"
		printf '    copy /odm/etc/%s /data/vendor/nfc/%s\n' "$seed_name" "$seed_name" >> "$temporary_seed_rc"
		printf '    chown nfc nfc /data/vendor/nfc/%s\n' "$seed_name" >> "$temporary_seed_rc"
		printf '    chmod 0660 /data/vendor/nfc/%s\n' "$seed_name" >> "$temporary_seed_rc"
		if cmp -s -- "$seed_src" "$seed_dst"; then
			skip_print "裸名配置已是最新：odm/etc/$seed_name"
			continue
		fi
		cp -p -- "$seed_src" "$temporary_seed_file"
		chmod 0644 -- "$temporary_seed_file"
		if ! replace_file_if_different "$temporary_seed_file" "$seed_dst"; then
			err_print "写入裸名 TMS 配置失败：odm/etc/$seed_name"
			exit 1
		fi
		if ! cmp -s -- "$seed_src" "$seed_dst"; then
			err_print "裸名 TMS 配置写回后与底包原件不一致：odm/etc/$seed_name"
			exit 1
		fi
		done

	chmod 0644 -- "$temporary_seed_rc"
	if ! replace_file_if_different "$temporary_seed_rc" "$tms_seed_rc_target"; then
		err_print "写入 TMS 配置播种 rc 失败：${tms_seed_rc_target#"$project_dir"/}"
		exit 1
	fi
	cp -p -- "$odm_metadata_contexts" "$temporary_seed_odm_ctx"
	cp -p -- "$odm_metadata_fsconfig" "$temporary_seed_odm_fs"
	merge_contexts_file "$temporary_seed_ctx" "$temporary_seed_odm_ctx"
	merge_fsconfig_file "$temporary_seed_fs" "$temporary_seed_odm_fs"
	_install_generated_file "$temporary_seed_odm_ctx" "$odm_metadata_contexts"
	_install_generated_file "$temporary_seed_odm_fs" "$odm_metadata_fsconfig"

	for seed_name in "${seed_names[@]}"; do
		if ! grep -Fqx "odm/etc/$seed_name 0 0 0644" "$odm_metadata_fsconfig"; then
			err_print "播种后 odm fsconfig 缺少条目：odm/etc/$seed_name"
			exit 1
		fi
	done
	if ! grep -Fqx '    mkdir /data/vendor/nfc 0777 nfc nfc' "$tms_seed_rc_target" || \
		! grep -Fqx '/odm/etc/init/nfc_tms_seed_config\.rc u:object_r:vendor_configs_file:s0' "$odm_metadata_contexts"; then
		err_print "TMS 配置播种 rc 或 odm metadata 写入后校验失败"
		exit 1
	fi
	std_print "✅ 已播种 ${#seed_names[@]} 个 TMS 运行配置（project=${tms_prjname}）：odm/etc 裸名 + post-fs-data 铺入 /data/vendor/nfc"
fi

std_print "处理完成"
