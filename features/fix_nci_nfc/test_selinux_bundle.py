#!/usr/bin/env python3
"""Contract tests for the fix_nci_nfc SELinux bundle."""

from __future__ import annotations

from pathlib import Path


PATCH_DIR = Path(__file__).resolve().parent
CONFIG_DIR = PATCH_DIR / "config"
BUNDLE = CONFIG_DIR / "selinux_bundle.tsv"
POLICY = CONFIG_DIR / "selinux_policy.cil.in"
PROPERTY_CONTEXTS = CONFIG_DIR / "nfc_property_contexts"
SERVICE_CONTEXTS = CONFIG_DIR / "nfc_service_contexts"


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
        ("contexts", "vendor_property_contexts", "config/nfc_property_contexts"),
        (
            "contexts",
            "precompiled_property_contexts",
            "config/nfc_property_contexts",
        ),
        ("contexts", "vendor_service_contexts", "config/nfc_service_contexts"),
        (
            "contexts",
            "precompiled_service_contexts",
            "config/nfc_service_contexts",
        ),
    ]
    assert POLICY.is_file() and not POLICY.is_symlink()
    assert PROPERTY_CONTEXTS.is_file() and not PROPERTY_CONTEXTS.is_symlink()
    assert SERVICE_CONTEXTS.is_file() and not SERVICE_CONTEXTS.is_symlink()


def test_policy_is_exact_and_minimal() -> None:
    active_statements = [
        line.strip()
        for line in POLICY.read_text(encoding="utf-8").splitlines()
        if line.strip().startswith("(")
    ]
    assert active_statements == [
        "(allow system_server_${API_VERSION} hal_nfc_default (process (signal)))",
        "(type vendor_nfc_mi_prop)",
        "(roletype object_r vendor_nfc_mi_prop)",
        "(typeattributeset property_type (vendor_nfc_mi_prop))",
        "(typeattributeset vendor_property_type (vendor_nfc_mi_prop))",
        "(typeattributeset vendor_public_property_type (vendor_nfc_mi_prop))",
        "(allow hal_nfc_default vendor_nfc_mi_prop (property_service (set)))",
        "(allow hal_nfc_default vendor_nfc_mi_prop (file (read getattr map open)))",
        "(allow hal_nfc_default property_socket_${API_VERSION} (sock_file (write)))",
        "(allow hal_nfc_default init_${API_VERSION} (unix_stream_socket (connectto)))",
        "(allow hal_secure_element_default vendor_nfc_mi_prop (property_service (set)))",
        "(allow hal_secure_element_default vendor_nfc_mi_prop (file (read getattr map open)))",
        "(allow nfc_${API_VERSION} vendor_nfc_mi_prop (file (read getattr map open)))",
        "(allow secure_element_${API_VERSION} vendor_nfc_mi_prop (file (read getattr map open)))",
        "(allow system_app_${API_VERSION} vendor_nfc_mi_prop (file (read getattr map open)))",
        "(allow vendor_init_${API_VERSION} vendor_nfc_mi_prop (property_service (set)))",
        "(allow vendor_init_${API_VERSION} vendor_nfc_mi_prop (file (read getattr map open)))",
    ]
    policy = POLICY.read_text(encoding="utf-8")
    for forbidden in ("permissive", "dontaudit", "allow *", "domain process"):
        assert forbidden not in policy


def test_property_contexts_are_narrow_and_typed() -> None:
    records = []
    for line_number, raw_line in enumerate(
        PROPERTY_CONTEXTS.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        assert len(fields) == 2, f"invalid context at {PROPERTY_CONTEXTS}:{line_number}"
        records.append(tuple(fields))
    assert records == [("ro.vendor.nfc.", "u:object_r:vendor_nfc_mi_prop:s0")]
    assert "(type vendor_nfc_mi_prop)" in POLICY.read_text(encoding="utf-8")


def test_service_contexts_restore_only_mi_nfc() -> None:
    records = []
    for line_number, raw_line in enumerate(
        SERVICE_CONTEXTS.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        assert len(fields) == 2, f"invalid context at {SERVICE_CONTEXTS}:{line_number}"
        records.append(tuple(fields))
    assert records == [("mi_nfc", "u:object_r:nfc_service:s0")]


def test_apply_validates_runtime_contract_before_writes() -> None:
    apply_source = (PATCH_DIR / "apply.sh").read_text(encoding="utf-8")
    assert 'load_selinux_bundle_manifest "$selinux_bundle_manifest"' in apply_source
    assert 'check_selinux_bundle_requirements "$project_dir"' in apply_source
    assert "expected_nfc_rule=" in apply_source
    assert "expected_nfc_policy_statements=" in apply_source
    assert "expected_property_fragment=" in apply_source
    assert "expected_service_fragment=" in apply_source
    assert "nfc_property_contexts" in apply_source
    assert "nfc_service_contexts" in apply_source
    assert "validate_nfc_policy_contract" in apply_source
    assert 'vendor_debug_policy="$vendor_selinux/vendor_sepolicy_debug.cil"' in apply_source
    assert "typetransition init_${api_version} hal_nfc_default_exec" in apply_source
    assert "u:object_r:hal_nfc_default_exec:s0" in apply_source


if __name__ == "__main__":
    test_bundle_contract()
    test_policy_is_exact_and_minimal()
    test_property_contexts_are_narrow_and_typed()
    test_service_contexts_restore_only_mi_nfc()
    test_apply_validates_runtime_contract_before_writes()
    print("fix_nci_nfc SELinux bundle tests passed")
