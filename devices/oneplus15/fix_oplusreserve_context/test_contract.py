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
    ]
    assert statements[0].endswith("(blk_file (create getattr setattr)))")
    policy = POLICY.read_text(encoding="utf-8")
    for forbidden in ("permissive", "dontaudit", "rild"):
        assert forbidden not in policy
    assert "filesystem (associate)" in policy
    assert "(allow mdm_feature oppo_block_device (blk_file (open read write)))" in policy
    apply_source = APPLY.read_text(encoding="utf-8")
    assert 'load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"' in apply_source
    assert 'check_selinux_bundle_requirements "$project_dir"' in apply_source
    assert "type ueventd" in apply_source
    assert "type oppo_block_device" in apply_source


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
