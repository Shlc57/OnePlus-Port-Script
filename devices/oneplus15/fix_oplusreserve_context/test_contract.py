#!/usr/bin/env python3
"""Static contract tests for the OnePlus 15 reserve block-device contexts."""

from pathlib import Path


MODULE = Path(__file__).resolve().parent
CONTEXTS = MODULE / "config/oplusreserve_file_contexts"
APPLY = MODULE / "apply.sh"
POLICY = MODULE / "config/selinux_policy.cil.in"
BUNDLE = MODULE / "config/selinux_bundle.tsv"
OP15 = MODULE.parents[2] / "OP15_port.sh"


def test_contexts() -> None:
    entries = CONTEXTS.read_text(encoding="utf-8").splitlines()
    assert entries == [
        "/dev/block/sdf2 u:object_r:oppo_block_device:s0",
    ]


def test_script_contract() -> None:
    text = APPLY.read_text(encoding="utf-8")
    assert 'merge_contexts_file "$contexts_patch" "$destination_file"' in text
    assert "oppo_block_device" in text
    assert "/dev/block/sdf2" in text
    assert "/dev/block/by-name/oplusreserve1" not in text
    assert "setenforce" not in text
    assert "secinfo" not in text


def test_ueventd_create_policy_contract() -> None:
    assert BUNDLE.read_text(encoding="utf-8").splitlines() == [
        "# 类型\t目标\t相对 fix_oplusreserve_context 目录的片段或项目内必需文件",
        "require\tproject\tvendor/etc/selinux/vendor_sepolicy.cil",
        "require\tproject\tvendor/etc/selinux/plat_pub_versioned.cil",
        "require\tproject\tsystem_ext/etc/selinux/system_ext_sepolicy.cil",
        "policy\tvendor_policy\tconfig/selinux_policy.cil.in",
    ]
    statements = [
        line.strip()
        for line in POLICY.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("(")
    ]
    assert statements == [
        "(allow ueventd oppo_block_device (blk_file (create getattr setattr)))",
        "(allow oppo_block_device tmpfs (filesystem (associate)))",
        "(allow mdm_feature oppo_block_device (blk_file (open read write)))",
        "(allow hal_charger_oplus oppo_block_device (blk_file (open read)))",
        "(allow oplus_hal_engineer_default oppo_block_device (blk_file (open read)))",
        "(allow oplus_hal_engineer_default oppo_reserve_file (dir (search)))",
        "(allow hal_oplus_sensor_aidl_default oppo_block_device (blk_file (open read)))",
        "(allow hal_oplus_misc_aidl_default oppo_block_device (blk_file (open read)))",
        "(allow hal_vibrator_default oppo_block_device (blk_file (open read)))",
        "(allow subsystem_daemon oppo_block_device (blk_file (open read)))",
        "(allow hal_gameopt_oplus_aidl domain (dir (search)))",
        "(allow hal_gameopt_oplus_aidl domain (file (read)))",
        "(allow hal_gameopt_oplus_aidl domain (file (open)))",
        "(allow hal_gameopt_oplus_aidl domain (file (getattr)))",
        "(allow init oppo_reserve_file (dir (relabelfrom)))",
        "(allow vendor_init oppo_reserve_file (dir (read relabelfrom)))",
        "(allow vendor_init oppo_reserve_file (file (getattr)))",
        "(allow vendor_init oppo_reserve_file (file (relabelfrom)))",
        "(allow vendor_init oppo_reserve_system_file (dir (search getattr setattr)))",
        "(allow vendor_init oppo_reserve_media_file (dir (search getattr setattr)))",
        "(allow vendor_init oppo_reserve_system_config (dir (getattr setattr)))",
        "(allow vendor_init oppo_reserve_media_log (dir (search getattr setattr)))",
        "(allow vendor_init oppo_reserve_system_file (dir (read relabelfrom)))",
        "(allow vendor_init oppo_reserve_media_file (dir (read relabelfrom)))",
        "(allow vendor_init oppo_reserve_system_config (dir (read relabelfrom)))",
        "(allow vendor_init oppo_reserve_media_log (dir (read relabelfrom)))",
        "(allow vendor_init oppo_reserve_system_config (file (getattr)))",
        "(allow vendor_init oppo_reserve_media_log (file (getattr)))",
        "(allow qsguard kmsg_device (chr_file (write)))",
        "(allow wlchg kmsg_device (chr_file (write)))",
        "(allow wlchg kmsg_device (chr_file (open)))",
        "(allow hal_urcc_default vendor_latency_device (chr_file (open)))",
        "(allow hal_charger_oplus oppo_block_device (blk_file (write)))",
        "(allow servicemanager vendor_hal_sensorscalibrate_qti_default (binder (call)))",
        "(allow cameramind_app vendor_hal_perf_default (binder (call)))",
        "(allow cameramind_app zygote (unix_stream_socket (getopt)))",
        "(allow vendor_wlc_app zygote (unix_stream_socket (getopt)))",
        "(allow vendor_timeservice_app zygote (unix_stream_socket (getopt)))",
        "(allow hal_graphics_composer_default vendor_smmu_proxy_device (chr_file (ioctl)))",
        "(allowx hal_graphics_composer_default vendor_smmu_proxy_device (ioctl chr_file (0x5500)))",
    ]
    assert statements[0].endswith("(blk_file (create getattr setattr)))")
    policy = POLICY.read_text(encoding="utf-8")
    for forbidden in ("permissive", "dontaudit", "allow domain", "rild"):
        assert forbidden not in policy
    assert "filesystem (associate)" in policy
    assert "(allow mdm_feature oppo_block_device (blk_file (open read write)))" in policy
    assert "(allow hal_gameopt_oplus_aidl domain (dir (search)))" in policy
    assert "(allow hal_gameopt_oplus_aidl domain (file (read)))" in policy
    assert "(allow hal_gameopt_oplus_aidl domain (file (open)))" in policy
    assert "(allow hal_gameopt_oplus_aidl domain (file (getattr)))" in policy
    assert "(allow qsguard kmsg_device (chr_file (write)))" in policy
    assert "(allow servicemanager vendor_hal_sensorscalibrate_qti_default (binder (call)))" in policy
    assert "(allow cameramind_app vendor_hal_perf_default (binder (call)))" in policy
    assert "(allow hal_graphics_composer_default vendor_smmu_proxy_device (chr_file (ioctl)))" in policy
    assert "(allowx hal_graphics_composer_default vendor_smmu_proxy_device (ioctl chr_file (0x5500)))" in policy
    apply_source = APPLY.read_text(encoding="utf-8")
    assert 'load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"' in apply_source
    assert 'check_selinux_bundle_requirements "$project_dir"' in apply_source
    assert "required_policy_types" in apply_source
    assert "    ueventd\n" in apply_source
    assert "    oppo_block_device\n" in apply_source
    assert "typeattribute domain" in apply_source
    assert "system_ext_sepolicy.cil" in apply_source


def test_op15_order() -> None:
    text = OP15.read_text(encoding="utf-8")
    reserve = text.index("devices/oneplus15/fix_oplusreserve_context")
    mi_account = text.index("common/fix_mi_account")
    vendor_avc = text.index("common/fix_vendor_avc")
    assert mi_account < reserve < vendor_avc


if __name__ == "__main__":
    test_contexts()
    test_script_contract()
    test_ueventd_create_policy_contract()
    test_op15_order()
    print("OnePlus 15 reserve context contract passed")
