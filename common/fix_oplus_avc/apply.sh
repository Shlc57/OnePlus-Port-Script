#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复 Oplus reserve AVC 与 mdm_feature 的 property contexts"
std_print "仅合并实测 Oplus AVC 和原包已有的 exported_default_prop 标签"
std_print

for part_name in vendor odm system_ext; do
	check_part_exists "$part_name"
done
check_partition_metadata_tool >/dev/null

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
odm_selinux_dir="$project_dir/odm/etc/selinux"
odm_property_contexts="$odm_selinux_dir/odm_property_contexts"
odm_metadata_contexts="$(get_part_contexts_path odm)"
odm_metadata_fsconfig="$(get_part_fsconfig_path odm)"
property_context_fragment="$patcher_dir/config/odm_property_contexts"
metadata_context_fragment="$patcher_dir/config/odm_metadata_contexts"
metadata_fsconfig_fragment="$patcher_dir/config/odm_fsconfig"

for required_file in \
	"$property_context_fragment" \
	"$metadata_context_fragment" \
	"$metadata_fsconfig_fragment" \
	"$odm_metadata_contexts" \
	"$odm_metadata_fsconfig"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "mdm_feature 输入不能是符号链接：$required_file"
		exit 1
	fi
done

if [[ -L "$odm_selinux_dir" || ! -d "$odm_selinux_dir" ]]; then
	err_print "ODM SELinux 目录不存在或不是普通目录：$odm_selinux_dir"
	exit 1
fi
if [[ -L "$odm_property_contexts" ]]; then
	err_print "ODM property contexts 不能是符号链接：$odm_property_contexts"
	exit 1
elif [[ -e "$odm_property_contexts" && ! -f "$odm_property_contexts" ]]; then
	err_print "ODM property contexts 不是普通文件：$odm_property_contexts"
	exit 1
fi

expected_property_contexts=(
	'ro.build.version.svn.c u:object_r:exported_default_prop:s0'
	'ro.build.version.svn u:object_r:exported_default_prop:s0'
	'ro.build.version.ota u:object_r:exported_default_prop:s0'
)
property_context_entry_count=0
while IFS=$' \t' read -r context_key context_value extra_field || \
	[[ -n "$context_key" || -n "$context_value" ]]; do
	context_key="${context_key%$'\r'}"
	context_value="${context_value%$'\r'}"
	extra_field="${extra_field%$'\r'}"
	[[ -z "$context_key" || "$context_key" == \#* ]] && continue
	if [[ -n "$extra_field" ]]; then
		err_print "mdm_feature property contexts 片段字段过多：$property_context_fragment"
		exit 1
	fi
	if ! printf '%s\n' "${expected_property_contexts[@]}" | \
		grep -Fqx "$context_key $context_value"; then
		err_print "mdm_feature property contexts 片段包含未声明条目：$context_key $context_value"
		exit 1
	fi
	property_context_entry_count=$((property_context_entry_count + 1))
done < "$property_context_fragment"
if (( property_context_entry_count != ${#expected_property_contexts[@]} )); then
	err_print "mdm_feature property contexts 片段条目数不正确：$property_context_fragment"
	exit 1
fi

if ! grep -Fqx \
	'/odm/etc/selinux/odm_property_contexts u:object_r:property_contexts_file:s0' \
	"$metadata_context_fragment" || \
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$metadata_context_fragment") != 1 )); then
	err_print "mdm_feature ODM contexts 片段不完整"
	exit 1
fi
if ! grep -Fqx \
	'odm/etc/selinux/odm_property_contexts 0 0 0644' \
	"$metadata_fsconfig_fragment" || \
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$metadata_fsconfig_fragment") != 1 )); then
	err_print "mdm_feature ODM fsconfig 片段不完整"
	exit 1
fi

contexts_patch="$patcher_dir/config/oplusreserve_file_contexts"
selinux_bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
selinux_policy_fragment="$patcher_dir/config/selinux_policy.cil.in"
# shellcheck disable=SC2154 # project_dir 由 init_port_env/tools.sh 导出。
vendor_file_contexts="$project_dir/vendor/etc/selinux/vendor_file_contexts"
precompiled_file_contexts="$project_dir/odm/etc/selinux/precompiled_file_contexts"
vendor_selinux="$project_dir/vendor/etc/selinux"
vendor_policy="$vendor_selinux/vendor_sepolicy.cil"
vendor_versioned_policy="$vendor_selinux/plat_pub_versioned.cil"
vendor_policy_version="$vendor_selinux/plat_sepolicy_vers.txt"
system_ext_policy="$project_dir/system_ext/etc/selinux/system_ext_sepolicy.cil"

for required_file in \
    "$contexts_patch" \
    "$selinux_bundle_manifest" \
    "$selinux_policy_fragment" \
    "$vendor_file_contexts" \
    "$precompiled_file_contexts" \
    "$vendor_policy" \
    "$vendor_versioned_policy" \
    "$vendor_policy_version" \
    "$system_ext_policy"; do
    check_file_exists "$required_file"
    if [[ -L "$required_file" ]]; then
        err_print "Oplus reserve SELinux 契约输入不能是符号链接：$required_file"
        exit 1
    fi
done

required_entry='/dev/block/sdf2 u:object_r:oppo_block_device:s0'
if ! grep -Fqx "$required_entry" "$contexts_patch"; then
    err_print "Oplus reserve contexts 缺少固定条目：$required_entry"
    exit 1
fi

load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"
check_selinux_bundle_requirements "$project_dir"
if [[ "$SELINUX_BUNDLE_ACTIVE" != true || \
    ${#SELINUX_BUNDLE_POLICY_FRAGMENTS[@]} != 1 || \
    ${#SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]} != 0 || \
    "${SELINUX_BUNDLE_POLICY_FRAGMENTS[0]}" != \
        "$(realpath -e -- "$selinux_policy_fragment")" ]]; then
    err_print "Oplus reserve SELinux bundle requirement 或策略片段不完整"
    exit 1
fi

api_version="$(tr -d '[:space:]' < "$vendor_policy_version")"
if [[ ! "$api_version" =~ ^[0-9]+$ ]]; then
    err_print "无法识别目标 SELinux policy API：$api_version"
    exit 1
fi
required_policy_types=(
    ueventd
    oppo_block_device
    mdm_feature
    hal_charger_oplus
    oplus_hal_engineer_default
    hal_oplus_sensor_aidl_default
    hal_oplus_misc_aidl_default
    hal_vibrator_default
    subsystem_daemon
    hal_gameopt_oplus_aidl
    init
    vendor_init
    oppo_reserve_file
    oppo_reserve_system_file
    oppo_reserve_media_file
    oppo_reserve_system_config
    oppo_reserve_media_log
    qsguard
    wlchg
    kmsg_device
    hal_urcc_default
    vendor_latency_device
    servicemanager
    vendor_hal_sensorscalibrate_qti_default
    cameramind_app
    vendor_hal_perf_default
    vendor_wlc_app
    vendor_timeservice_app
    zygote
    hal_graphics_composer_default
    vendor_smmu_proxy_device
    hal_bluetooth_default
    hal_bootctl_default
    hal_contexthub_default
    vendor_hal_gatekeeper_qti
    vendor_hal_gnss_qti
    vendor_bluetooth_prop
    vendor_oplus_prop
    radio_prop
    config_prop
    system_prop
)
for required_policy_type in "${required_policy_types[@]}"; do
    if ! grep -Fqx "(type $required_policy_type)" "$vendor_policy" && \
        ! grep -Fqx "(type $required_policy_type)" "$vendor_versioned_policy" && \
        ! grep -Fqx "(type $required_policy_type)" "$system_ext_policy"; then
        err_print "目标策略缺少 Oplus AVC 所需类型：$required_policy_type"
        exit 1
    fi
done
if ! grep -Fqx "(typeattribute domain)" "$vendor_versioned_policy"; then
    err_print "目标策略缺少 gameopt /proc 枚举所需 domain 属性"
    exit 1
fi
required_policy_rules=(
    '(allow ueventd oppo_block_device (blk_file (create getattr setattr)))'
    '(allow oppo_block_device tmpfs (filesystem (associate)))'
    '(allow mdm_feature oppo_block_device (blk_file (open read write)))'
    '(allow hal_charger_oplus oppo_block_device (blk_file (open read)))'
    '(allow oplus_hal_engineer_default oppo_block_device (blk_file (open read)))'
    '(allow oplus_hal_engineer_default oppo_reserve_file (dir (search)))'
    '(allow hal_oplus_sensor_aidl_default oppo_block_device (blk_file (open read)))'
    '(allow hal_oplus_misc_aidl_default oppo_block_device (blk_file (open read)))'
    '(allow hal_vibrator_default oppo_block_device (blk_file (open read)))'
    '(allow subsystem_daemon oppo_block_device (blk_file (open read)))'
    '(allow hal_gameopt_oplus_aidl domain (dir (search)))'
    '(allow hal_gameopt_oplus_aidl domain (file (read)))'
    '(allow hal_gameopt_oplus_aidl domain (file (open)))'
    '(allow hal_gameopt_oplus_aidl domain (file (getattr)))'
    '(allow init oppo_reserve_file (dir (relabelfrom)))'
    '(allow vendor_init oppo_reserve_file (dir (read relabelfrom)))'
    '(allow vendor_init oppo_reserve_file (file (getattr)))'
    '(allow vendor_init oppo_reserve_file (file (relabelfrom)))'
    '(allow vendor_init oppo_reserve_system_file (dir (search getattr setattr)))'
    '(allow vendor_init oppo_reserve_media_file (dir (search getattr setattr)))'
    '(allow vendor_init oppo_reserve_system_config (dir (getattr setattr)))'
    '(allow vendor_init oppo_reserve_media_log (dir (search getattr setattr)))'
    '(allow vendor_init oppo_reserve_system_file (dir (read relabelfrom)))'
    '(allow vendor_init oppo_reserve_media_file (dir (read relabelfrom)))'
    '(allow vendor_init oppo_reserve_system_config (dir (read relabelfrom)))'
    '(allow vendor_init oppo_reserve_media_log (dir (read relabelfrom)))'
    '(allow vendor_init oppo_reserve_system_config (file (getattr)))'
    '(allow vendor_init oppo_reserve_media_log (file (getattr)))'
    '(allow vendor_init oppo_reserve_system_config (file (relabelfrom)))'
    '(allow vendor_init oppo_reserve_media_log (file (relabelfrom)))'
    '(allow qsguard kmsg_device (chr_file (write)))'
    '(allow wlchg kmsg_device (chr_file (write)))'
    '(allow wlchg kmsg_device (chr_file (open)))'
    '(allow hal_urcc_default vendor_latency_device (chr_file (open)))'
    '(allow hal_charger_oplus oppo_block_device (blk_file (write)))'
    '(allow servicemanager vendor_hal_sensorscalibrate_qti_default (binder (call)))'
    '(allow cameramind_app vendor_hal_perf_default (binder (call)))'
    '(allow cameramind_app zygote (unix_stream_socket (getopt)))'
    '(allow vendor_wlc_app zygote (unix_stream_socket (getopt)))'
    '(allow vendor_timeservice_app zygote (unix_stream_socket (getopt)))'
    '(allow hal_graphics_composer_default vendor_smmu_proxy_device (chr_file (ioctl)))'
    '(allowx hal_graphics_composer_default vendor_smmu_proxy_device (ioctl chr_file (0x5500)))'
    '(allow system_app_202504 hal_bluetooth_default (binder (call)))'
    '(allow system_app_202504 hal_bootctl_default (binder (call)))'
    '(allow system_app_202504 hal_contexthub_default (binder (call)))'
    '(allow system_app_202504 vendor_hal_gatekeeper_qti (binder (call)))'
    '(allow system_app_202504 vendor_hal_gnss_qti (binder (call)))'
    '(allow shell_202504 vendor_hal_perf_default (binder (call)))'
    '(allow permissioncontroller_app zygote (unix_stream_socket (getopt)))'
    '(allow updater zygote (unix_stream_socket (getopt)))'
    '(allow traceur_app zygote (unix_stream_socket (getopt)))'
    '(allow priv_app zygote (unix_stream_socket (getopt)))'
    '(allow mediaprovider zygote (unix_stream_socket (getopt)))'
    '(allow shell_202504 zygote (unix_stream_socket (getopt)))'
    '(allow untrusted_app_34 zygote (unix_stream_socket (getopt)))'
    '(allow untrusted_app_30 zygote (unix_stream_socket (getopt)))'
    '(allow vendor_init_202504 radio_prop (property_service (set)))'
    '(allow vendor_qti_init_shell vendor_bluetooth_prop (property_service (set)))'
    '(allow vendor_qti_init_shell vendor_oplus_prop (property_service (set)))'
    '(allow mdm_feature vendor_oplus_prop (property_service (set)))'
    '(allow vendor_init_202504 config_prop (property_service (set)))'
    '(allow platform_app system_prop (property_service (set)))'
    '(allow platform_app_36 system_prop (property_service (set)))'
)
for required_policy_rule in "${required_policy_rules[@]}"; do
    if ! grep -Fqx "$required_policy_rule" "$selinux_policy_fragment"; then
        err_print "Oplus reserve SELinux 片段缺少精确规则：$required_policy_rule"
        exit 1
    fi
done
if (( $(grep -Ec '^[[:space:]]*\(' "$selinux_policy_fragment") != ${#required_policy_rules[@]} )); then
    err_print "Oplus reserve SELinux 片段包含非预期规则"
    exit 1
fi

merge_one_contexts() {
    local destination_file="${1:-}"

    if [[ ! -e "$destination_file" ]]; then
        warn_print "file contexts 目标不存在，跳过：${destination_file#"$project_dir"/}"
        return 0
    fi
    if [[ -L "$destination_file" || ! -f "$destination_file" ]]; then
        err_print "file contexts 目标不是普通文件：$destination_file"
        return 1
    fi
    merge_contexts_file "$contexts_patch" "$destination_file"
    if ! grep -Fqx "$required_entry" "$destination_file"; then
        err_print "file contexts 写回后缺少条目：${destination_file#"$project_dir"/}"
        return 1
    fi
}

temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

temporary_property_contexts="$(mktemp "$(get_config_path '.fix_oplus_avc_property_contexts.XXXXXX')")"
temporary_odm_contexts="$(mktemp "$(get_config_path '.fix_oplus_avc_odm_contexts.XXXXXX')")"
temporary_odm_fsconfig="$(mktemp "$(get_config_path '.fix_oplus_avc_odm_fsconfig.XXXXXX')")"
temporary_files+=(
	"$temporary_property_contexts"
	"$temporary_odm_contexts"
	"$temporary_odm_fsconfig"
)

# 保留已有 ODM property contexts（例如 LTPO 的 ADFR 条目），只按路径覆盖
# mdm_feature 所需的三个精确属性。目标不存在时才创建最小新文件。
if [[ -e "$odm_property_contexts" ]]; then
	cp -p -- "$odm_property_contexts" "$temporary_property_contexts"
	merge_contexts_file "$property_context_fragment" "$temporary_property_contexts"
else
	cp -p -- "$property_context_fragment" "$temporary_property_contexts"
	chmod 0644 -- "$temporary_property_contexts"
fi

for expected_context in "${expected_property_contexts[@]}"; do
	expected_key="${expected_context%% *}"
	expected_value="${expected_context#* }"
	if (( $(awk -v key="$expected_key" '$1 == key { count++ } END { print count + 0 }' \
		"$temporary_property_contexts") != 1 )) || \
		! awk -v key="$expected_key" -v value="$expected_value" \
		'$1 == key && $2 == value { found = 1 } END { exit found ? 0 : 1 }' \
		"$temporary_property_contexts"; then
		err_print "生成的 ODM property contexts 缺少唯一正确条目：$expected_key"
		exit 1
	fi
done

cp -p -- "$odm_metadata_contexts" "$temporary_odm_contexts"
cp -p -- "$odm_metadata_fsconfig" "$temporary_odm_fsconfig"
merge_contexts_file "$metadata_context_fragment" "$temporary_odm_contexts"
merge_fsconfig_file "$metadata_fsconfig_fragment" "$temporary_odm_fsconfig"

if ! grep -Fqx \
	'/odm/etc/selinux/odm_property_contexts u:object_r:property_contexts_file:s0' \
	"$temporary_odm_contexts" || \
	! grep -Fqx \
	'odm/etc/selinux/odm_property_contexts 0 0 0644' \
	"$temporary_odm_fsconfig"; then
	err_print "生成的 ODM property contexts metadata 不完整"
	exit 1
fi

_install_generated_file "$temporary_odm_contexts" "$odm_metadata_contexts"
_install_generated_file "$temporary_odm_fsconfig" "$odm_metadata_fsconfig"
if [[ -e "$odm_property_contexts" ]]; then
	_install_generated_file "$temporary_property_contexts" "$odm_property_contexts"
else
	replace_file_if_different "$temporary_property_contexts" "$odm_property_contexts"
fi

merge_one_contexts "$vendor_file_contexts"
merge_one_contexts "$precompiled_file_contexts"

std_print "✅ 已恢复 ro.build.version.svn.c、ro.build.version.svn、ro.build.version.ota 标签"
std_print "✅ 已登记 /dev/block/sdf2 的 oppo_block_device 标签与 Oplus 最小 AVC bundle"
std_print "ℹ️ 不写入属性值；SVN/OTA 实际值仍由底包属性来源提供"
std_print "处理完成"
