#!/usr/bin/env python3
"""Contract tests for DisplayFeature/RGB property contexts."""

from __future__ import annotations

from pathlib import Path


PATCH_DIR = Path(__file__).resolve().parent
CONTEXTS = PATCH_DIR / "config/display_property_contexts"
BUNDLE = PATCH_DIR / "config/selinux_bundle.tsv"
POLICY = PATCH_DIR / "config/selinux_policy.cil.in"


def context_records() -> list[tuple[str, str]]:
    records = []
    for line in CONTEXTS.read_text(encoding="utf-8").splitlines():
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = tuple(stripped.split())
        assert len(fields) == 2
        records.append(fields)  # type: ignore[arg-type]
    return records


def test_display_property_contexts_are_exact() -> None:
    assert context_records() == [
        ("ro.vendor.colorpick_adjust", "u:object_r:vendor_display_prop:s0"),
        ("ro.vendor.all_modes.colorpick_adjust", "u:object_r:vendor_display_prop:s0"),
        ("vendor.panel.color", "u:object_r:vendor_display_prop:s0"),
        ("ro.oplus.display.rgb_ball_min_value", "u:object_r:vendor_display_prop:s0"),
        ("ro.oplus.display.rgb_ball_max_value", "u:object_r:vendor_display_prop:s0"),
        ("ro.oplus.display.colormode.vivid", "u:object_r:vendor_display_prop:s0"),
        ("ro.oplus.display.smarteyecare.v5", "u:object_r:vendor_display_prop:s0"),
        ("ro.oplus.display.lcd_eyeprotect_module", "u:object_r:vendor_display_prop:s0"),
        ("ro.oplus.display.screenSizeInches.primary", "u:object_r:vendor_display_prop:s0"),
        ("ro.oplus.display.screenSizeCentimeter.primary", "u:object_r:vendor_display_prop:s0"),
    ]


def test_bundle_registers_both_property_context_targets() -> None:
    records = [
        tuple(line.split("\t"))
        for line in BUNDLE.read_text(encoding="utf-8").splitlines()
        if line and not line.startswith("#")
    ]
    assert ("contexts", "vendor_property_contexts", "config/display_property_contexts") in records
    assert ("contexts", "precompiled_property_contexts", "config/display_property_contexts") in records
    assert ("policy", "vendor_policy", "config/selinux_policy.cil.in") in records


def test_policy_keeps_display_bridge_rules_only() -> None:
    policy_lines = [
        line.strip()
        for line in POLICY.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("(")
    ]
    assert policy_lines == [
        "(allow servicemanager_${API_VERSION} vendor_hal_display_color_server (binder (call)))",
        "(allow vendor_hal_display_color_default surfaceflinger_${API_VERSION} (binder (call)))",
        "(allow vendor_hal_display_color_default surfaceflinger_service_${API_VERSION} (service_manager (find)))",
        "(typeattributeset vendor_hal_display_color_client (system_server_${API_VERSION}))",
    ]


if __name__ == "__main__":
    test_display_property_contexts_are_exact()
    test_bundle_registers_both_property_context_targets()
    test_policy_keeps_display_bridge_rules_only()
    print("display property bundle tests passed")
