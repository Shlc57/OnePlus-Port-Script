#!/usr/bin/env python3
"""Contract tests for the fix_nfc SELinux bundle."""

from __future__ import annotations

from pathlib import Path


PATCH_DIR = Path(__file__).resolve().parent
CONFIG_DIR = PATCH_DIR / "config"
BUNDLE = CONFIG_DIR / "selinux_bundle.tsv"
POLICY = CONFIG_DIR / "selinux_policy.cil.in"


def parse_tsv(path: Path) -> list[tuple[str, str, str]]:
    records: list[tuple[str, str, str]] = []
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        if not raw_line or raw_line.startswith("#"):
            continue
        fields = tuple(raw_line.split("\t"))
        assert len(fields) == 3, f"invalid TSV at {path}:{line_number}"
        records.append(fields)  # type: ignore[arg-type]
    assert records, f"empty TSV: {path}"
    assert len(records) == len(set(records)), f"duplicate records: {path}"
    return records


def test_bundle_contract() -> None:
    records = parse_tsv(BUNDLE)
    assert records == [
        (
            "require",
            "project",
            "odm/bin/hw/android.hardware.nfc-service.nxp",
        ),
        ("require", "project", "odm/etc/init/nfc-service-nxp.rc"),
        ("require", "project", "odm/etc/vintf/manifest/nfc-service.xml"),
        ("policy", "vendor_policy", "config/selinux_policy.cil.in"),
    ]
    assert POLICY.is_file() and not POLICY.is_symlink()


def test_policy_is_exact_and_minimal() -> None:
    active_statements = [
        line.strip()
        for line in POLICY.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("(")
    ]
    assert active_statements == [
        "(allow system_server_${API_VERSION} hal_nfc_default "
        "(process (signal)))"
    ]
    policy = POLICY.read_text(encoding="utf-8")
    for forbidden in ("permissive", "dontaudit", "allow *", "domain process"):
        assert forbidden not in policy


def test_apply_validates_runtime_contract_before_writes() -> None:
    apply_source = (PATCH_DIR / "apply.sh").read_text(encoding="utf-8")
    assert 'load_selinux_bundle_manifest "$selinux_bundle_manifest"' in apply_source
    assert 'check_selinux_bundle_requirements "$project_dir"' in apply_source
    assert "expected_nfc_rule=" in apply_source
    assert "grep -Ec '^[[:space:]]*\\('" in apply_source
    assert "validate_nfc_policy_contract" in apply_source
    assert 'vendor_debug_policy="$vendor_selinux/vendor_sepolicy_debug.cil"' in apply_source
    assert "typetransition init_${api_version} hal_nfc_default_exec" in apply_source
    assert "u:object_r:hal_nfc_default_exec:s0" in apply_source


if __name__ == "__main__":
    test_bundle_contract()
    test_policy_is_exact_and_minimal()
    test_apply_validates_runtime_contract_before_writes()
    print("fix_nfc SELinux bundle tests passed")
