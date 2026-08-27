#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复一加 15 Oplus reserve 块设备 SELinux 标签"
std_print "将实际 /dev/block/sdf2 映射到 oppo_block_device"
std_print "补齐实测 Oplus 底层 AVC 的最小 allow；不新增 rild allow"
std_print

for part_name in vendor odm system_ext; do
    check_part_exists "$part_name"
done
check_partition_metadata_tool >/dev/null

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

merge_one_contexts "$vendor_file_contexts"
merge_one_contexts "$precompiled_file_contexts"

std_print "✅ 已登记 /dev/block/sdf2 的 oppo_block_device 标签"
std_print "✅ 已登记 Oplus reserve、gameopt、HAL 与守护进程的实测最小 SELinux 规则，交由 common/fix_vendor_avc 统一合并"
std_print "该修改需在下一次 DSU Enforcing 冷启动后复核 Oplus AVC 增量"
