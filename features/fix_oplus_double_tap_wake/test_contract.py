#!/usr/bin/env python3
"""Static contract tests for the Oplus double-tap wake bridge feature."""

from __future__ import annotations

import re
from pathlib import Path


PATCH_DIR = Path(__file__).resolve().parent
CONFIG_DIR = PATCH_DIR / "config"
BUNDLE = CONFIG_DIR / "selinux_bundle.tsv"
POLICY = CONFIG_DIR / "selinux_policy.cil.in"


def parse_tsv(path: Path, fields: int) -> list[tuple[str, ...]]:
    records: list[tuple[str, ...]] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw_line or raw_line.startswith("#"):
            continue
        record = tuple(raw_line.split("\t"))
        assert len(record) == fields, f"invalid TSV at {path}:{line_number}"
        records.append(record)
    assert records and len(records) == len(set(records)), path
    return records


def context_records(path: Path) -> list[tuple[str, str]]:
    records: list[tuple[str, str]] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        assert len(fields) == 2, f"invalid context at {path}:{line_number}"
        assert re.fullmatch(r"u:object_r:[A-Za-z0-9_]+:s0", fields[1])
        records.append((fields[0].replace("\\", ""), fields[1]))
    assert records, path
    return records


def test_bundle_contract() -> None:
    records = parse_tsv(BUNDLE, 3)
    requirements = {
        relative_path
        for kind, target, relative_path in records
        if kind == "require" and target == "project"
    }
    assert requirements == {
        "odm/bin/hw/vendor.dna.hardware.touchfeature-oplus-bridge",
        "odm/etc/init/vendor.dna.hardware.touchfeature-oplus-bridge.rc",
        "odm/etc/vintf/manifest/vendor.dna.hardware.touchfeature-oplus-bridge.xml",
    }
    contexts = [
        (target, relative_path)
        for kind, target, relative_path in records
        if kind == "contexts"
    ]
    assert [target for target, _ in contexts] == [
        "vendor_file_contexts",
        "precompiled_file_contexts",
        "odm_metadata_contexts",
        "vendor_property_contexts",
        "precompiled_property_contexts",
        "vendor_service_contexts",
        "precompiled_service_contexts",
    ]
    for _, relative_path in contexts:
        fragment = PATCH_DIR / relative_path
        assert fragment.is_file() and not fragment.is_symlink(), fragment


def test_policy_has_independent_minimal_domain() -> None:
    policy = POLICY.read_text(encoding="utf-8")
    fragments = {
        PATCH_DIR / relative_path
        for kind, _, relative_path in parse_tsv(BUNDLE, 3)
        if kind == "contexts"
    }
    for fragment in fragments:
        for _, context in context_records(fragment):
            context_type = context.split(":")[2]
            assert f"(type {context_type})" in policy, context_type

    for required in (
        "(type hal_touchfeature_oplus_bridge)",
        "(type hal_touchfeature_oplus_bridge_exec)",
        "(type hal_touchfeature_oplus_bridge_service)",
        "(type vendor_touchfeature_compat_prop)",
        "(typeattributeset hal_oplus_touch_aidl_client "
        "(hal_touchfeature_oplus_bridge))",
        "(allow system_server_${API_VERSION} "
        "hal_touchfeature_oplus_bridge (binder (call)))",
        "(allow system_app_${API_VERSION} "
        "hal_touchfeature_oplus_bridge (binder (call)))",
        "(allow system_server_${API_VERSION} "
        "vendor_touchfeature_compat_prop (file (read getattr map open)))",
    ):
        assert required in policy
    assert not re.search(
        r"\(allow system_app_\$\{API_VERSION\} "
        r"hal_touchfeature_oplus_bridge \(binder \([^)]*transfer",
        policy,
    )
    assert "hal_touchfeature_xiaomi_default" not in policy
    assert not re.search(r"/dev/(?:hbp|tp)|proc_touchpanel|sysfs_touch", policy)


def test_interface_and_keylayout_templates() -> None:
    source = (PATCH_DIR / "src/touchfeature_oplus_bridge.cpp").read_text(
        encoding="utf-8"
    )
    assert "kXiaomiSetModeValueTransaction = 9" in source
    assert "kOplusTouchWriteNodeTransaction = 4" in source
    assert "kXiaomiDoubleTapMode = 14" in source
    assert "AIBinder_prepareTransaction(backend, &input)" in source
    assert "AParcel_readStatusHeader(output, &service_status)" in source
    assert "status == STATUS_DEAD_OBJECT" in source
    assert "release_oplus_service_locked()" in source
    assert "AIBinder_isAlive(g_state.oplus_service)" in source
    assert "AIBinder_markVintfStability(g_state.xiaomi_service)" in source
    assert 'write_oplus_node_locked(g_state.config.gesture_enable_node, "0")' in source
    assert 'write_oplus_node_locked(g_state.config.gesture_enable_node, "1")' in source

    keylayout = (CONFIG_DIR / "keylayout.kl.in").read_text(encoding="utf-8")
    assert "key @SCAN_CODE@ F4 WAKE" in keylayout
    rc = (
        CONFIG_DIR / "vendor.dna.hardware.touchfeature-oplus-bridge.rc.in"
    ).read_text(encoding="utf-8")
    for placeholder in (
        "@PANEL_ID@",
        "@GESTURE_CFG_NODE@",
        "@GESTURE_ENABLE_NODE@",
        "@GESTURE_CFG_VALUE@",
    ):
        assert placeholder in rc
    assert "interface aidl vendor.xiaomi.hw.touchfeature.ITouchFeature/default" in rc


def test_oneplus15_integration_parameters() -> None:
    port_dir = PATCH_DIR.parents[1]
    parameter_file = port_dir / "devices/oneplus15/config/double_tap_wake.props"
    parameters: dict[str, str] = {}
    for raw_line in parameter_file.read_text(encoding="utf-8").splitlines():
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key, separator, value = stripped.partition("=")
        assert separator and key not in parameters and value
        parameters[key] = value
    assert parameters == {
        "oplus.double_tap.panel_id": "0",
        "oplus.double_tap.gesture_cfg_node": "4100",
        "oplus.double_tap.gesture_enable_node": "4101",
        "oplus.double_tap.gesture_cfg_value": "2",
        "oplus.double_tap.input_device_name": "touchpanel",
        "oplus.double_tap.scan_code": "62",
        "oplus.double_tap.touchfeature_type": "247",
    }

    op15_entry = (port_dir / "OP15_port.sh").read_text(encoding="utf-8")
    assert (
        'export OPLUS_DOUBLE_TAP_PROPERTIES_FILE='
        '"$oneplus15_config_dir/double_tap_wake.props"'
    ) in op15_entry
    feature_position = op15_entry.index("features/fix_oplus_double_tap_wake")
    policy_position = op15_entry.index("common/fix_vendor_avc")
    assert feature_position < policy_position


if __name__ == "__main__":
    test_bundle_contract()
    test_policy_has_independent_minimal_domain()
    test_interface_and_keylayout_templates()
    test_oneplus15_integration_parameters()
    print("fix_oplus_double_tap_wake contract tests passed")
