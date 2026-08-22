#!/usr/bin/env python3
"""Contract tests for the ultrasonic fingerprint SELinux bundle."""

from __future__ import annotations

from pathlib import Path


PATCH_DIR = Path(__file__).resolve().parent
CONFIG_DIR = PATCH_DIR / "config"
BUNDLE = CONFIG_DIR / "selinux_bundle.tsv"
POLICY = CONFIG_DIR / "selinux_policy.cil.in"
CONTEXTS = CONFIG_DIR / "fingerprint_property_contexts"


def records(path: Path) -> list[tuple[str, str, str]]:
    parsed: list[tuple[str, str, str]] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw_line or raw_line.startswith("#"):
            continue
        fields = tuple(raw_line.split("\t"))
        assert len(fields) == 3, f"invalid TSV at {path}:{line_number}"
        parsed.append(fields)  # type: ignore[arg-type]
    return parsed


def context_records(path: Path) -> list[tuple[str, str]]:
    parsed: list[tuple[str, str]] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = tuple(stripped.split())
        assert len(fields) == 2, f"invalid context at {path}:{line_number}"
        parsed.append(fields)  # type: ignore[arg-type]
    return parsed


def test_bundle_contract() -> None:
    assert records(BUNDLE) == [
        ("require", "project", "odm/build.prop"),
        ("policy", "vendor_policy", "config/selinux_policy.cil.in"),
        (
            "contexts",
            "vendor_property_contexts",
            "config/fingerprint_property_contexts",
        ),
        (
            "contexts",
            "precompiled_property_contexts",
            "config/fingerprint_property_contexts",
        ),
    ]


def test_policy_is_narrow_and_versioned() -> None:
    statements = [
        line.strip()
        for line in POLICY.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("(")
    ]
    assert statements == [
        "(typeattributeset oppo_fingerprint_prop_${API_VERSION} (oppo_fingerprint_prop))",
        "(type vendor_ultrasonic_fp_compat_prop)",
        "(roletype object_r vendor_ultrasonic_fp_compat_prop)",
        "(typeattributeset property_type (vendor_ultrasonic_fp_compat_prop))",
        "(typeattributeset vendor_property_type (vendor_ultrasonic_fp_compat_prop))",
        "(typeattributeset vendor_public_property_type (vendor_ultrasonic_fp_compat_prop))",
        "(allow vendor_init_${API_VERSION} vendor_ultrasonic_fp_compat_prop (property_service (set)))",
        "(allow vendor_init_${API_VERSION} vendor_ultrasonic_fp_compat_prop (file (read getattr map open)))",
        "(allow system_server_${API_VERSION} vendor_ultrasonic_fp_compat_prop (file (read getattr map open)))",
        "(allow system_app_${API_VERSION} vendor_ultrasonic_fp_compat_prop (file (read getattr map open)))",
        "(allow platform_app_${API_VERSION} vendor_ultrasonic_fp_compat_prop (file (read getattr map open)))",
        "(allow surfaceflinger_${API_VERSION} vendor_ultrasonic_fp_compat_prop (file (read getattr map open)))",
        "(allow hal_fingerprint_oppo vendor_ultrasonic_fp_compat_prop (file (read getattr map open)))",
        "(allow zygote_${API_VERSION} vendor_ultrasonic_fp_compat_prop (file (read getattr map open)))",
    ]
    policy = POLICY.read_text(encoding="utf-8")
    for forbidden in (
        "permissive",
        "dontaudit",
        "exported_default_prop",
        "vendor_finerprint_optical_rawdata",
        "property_service (set)))\\n(allow hal_fingerprint_oppo",
    ):
        assert forbidden not in policy


def test_contexts_cover_only_observed_fingerprint_properties() -> None:
    assert context_records(CONTEXTS) == [
        ("ro.hardware.fp.fod.", "u:object_r:vendor_ultrasonic_fp_compat_prop:s0"),
        ("ro.hardware.fp.fod", "u:object_r:vendor_ultrasonic_fp_compat_prop:s0"),
        (
            "persist.vendor.sys.fp.vendor",
            "u:object_r:vendor_ultrasonic_fp_compat_prop:s0",
        ),
        (
            "persist.vendor.sys.fp.fod.",
            "u:object_r:vendor_ultrasonic_fp_compat_prop:s0",
        ),
        ("vendor.fingerprint.aidl.support", "u:object_r:oppo_fingerprint_prop:s0"),
        (
            "persist.vendor.fingerprint.optical.support",
            "u:object_r:oppo_fingerprint_prop:s0",
        ),
        ("oplus.fingerprint.gf.package.version", "u:object_r:oppo_fingerprint_prop:s0"),
        ("oplus.fingerprint.qrcode.support", "u:object_r:oppo_fingerprint_prop:s0"),
        ("oplus.fingerprint.qrcode.value", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.brightness.strategy", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.brightness.threshold", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.fp_id", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.optical.circlenumber", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.optical.iconlocation", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.optical.iconnumber", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.optical.iconsize", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.optical.sensorlocation", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.optical.sensorrotation", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.sensor_type", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.fingerprint.version", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.side.fp.near.feature.support", "u:object_r:oppo_fingerprint_prop:s0"),
        ("vendor.fingerprint.cali", "u:object_r:oppo_fingerprint_prop:s0"),
        ("vendor.fingerprint.meminfo", "u:object_r:oppo_fingerprint_prop:s0"),
        ("persist.vendor.rpmb.enable.state", "u:object_r:powerctl_prop:s0"),
    ]


def test_apply_uses_the_bundle_before_writing_properties() -> None:
    apply_source = (PATCH_DIR / "apply.sh").read_text(encoding="utf-8")
    assert 'load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"' in apply_source
    assert 'check_selinux_bundle_requirements "$project_dir"' in apply_source
    assert "(type hal_fingerprint_oppo)" in apply_source
    assert "(type oppo_fingerprint_prop)" in apply_source
    assert "oppo_fingerprint_prop_${api_version}" in apply_source
    assert "platform_app_${api_version}" in apply_source
    assert "vendor_ultrasonic_fp_compat_prop" in apply_source
    assert 'patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"' in apply_source
    assert apply_source.index("load_selinux_bundle_manifest") < apply_source.index(
        'merge_prop_file "$fingerprint_prop_patch" "$odm_build_prop"'
    )


if __name__ == "__main__":
    test_bundle_contract()
    test_policy_is_narrow_and_versioned()
    test_contexts_cover_only_observed_fingerprint_properties()
    test_apply_uses_the_bundle_before_writing_properties()
    print("ultrasonic fingerprint SELinux bundle tests passed")
