#!/usr/bin/env python3
"""Contract tests for the fix_mi_account SELinux bundle."""

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
    assert records, f"empty TSV: {path}"
    assert len(records) == len(set(records)), f"duplicate records: {path}"
    return records


def active_context_records(path: Path) -> list[tuple[str, str]]:
    records: list[tuple[str, str]] = []
    seen: set[str] = set()
    for line_number, raw_line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), start=1
    ):
        stripped = raw_line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        assert len(fields) == 2, f"invalid context at {path}:{line_number}"
        key = fields[0].replace("\\", "")
        assert key not in seen, f"duplicate context key {key}: {path}"
        seen.add(key)
        assert re.fullmatch(r"u:object_r:[A-Za-z0-9_]+:s0", fields[1])
        records.append((key, fields[1]))
    assert records, f"empty context fragment: {path}"
    return records


def test_bundle_ownership_and_targets() -> None:
    records = parse_tsv(BUNDLE, 3)
    requirements = {path for kind, target, path in records if kind == "require" and target == "project"}
    assert requirements == {
        "odm/bin/mtd",
        "odm/bin/mtd_check",
        "odm/bin/mtd_keysoter",
        "odm/etc/init/vendor.xiaomi.hardware.aidl.mtdservice-service.rc",
        "odm/etc/init/vendor.xiaomi.hardware.aidl.mtd_check-service.rc",
        "odm/etc/init/vendor.xiaomi.hardware.aidl.mtkeysoter-service.rc",
    }
    policies = [(target, path) for kind, target, path in records if kind == "policy"]
    assert policies == [("vendor_policy", "config/selinux_policy.cil.in")]
    contexts = [(target, path) for kind, target, path in records if kind == "contexts"]
    assert contexts == [
        ("vendor_file_contexts", "config/mtd_file_contexts"),
        ("precompiled_file_contexts", "config/mtd_file_contexts"),
        ("odm_metadata_contexts", "config/mtd_odm_contexts"),
        ("vendor_property_contexts", "config/mtd_property_contexts"),
        ("precompiled_property_contexts", "config/mtd_property_contexts"),
        ("vendor_service_contexts", "config/mtd_service_contexts"),
        ("precompiled_service_contexts", "config/mtd_service_contexts"),
    ]
    for _, relative_path in policies + contexts:
        fragment = PATCH_DIR / relative_path
        assert fragment.is_file() and not fragment.is_symlink(), fragment


def test_requirements_are_owned_by_source_manifest() -> None:
    source_manifests = {
        "odm": set(parse_tsv(CONFIG_DIR / "mi_odm_sources.tsv", 2)),
        "vendor": set(parse_tsv(CONFIG_DIR / "mi_vendor_sources.tsv", 2)),
    }
    for kind, target, requirement in parse_tsv(BUNDLE, 3):
        if kind != "require":
            continue
        assert target == "project"
        partition, relative_path = requirement.split("/", 1)
        assert ("replace", relative_path) in source_manifests[partition]


def test_context_types_and_independent_domains() -> None:
    policy = POLICY.read_text(encoding="utf-8")
    fragment_paths = {
        PATCH_DIR / relative_path
        for kind, _, relative_path in parse_tsv(BUNDLE, 3)
        if kind == "contexts"
    }
    for fragment_path in fragment_paths:
        for _, context in active_context_records(fragment_path):
            context_type = context.split(":")[2]
            assert f"(type {context_type})" in policy, context_type

    for domain, executable in (
        ("hal_mtdservice_check", "hal_mtdservice_check_exec"),
        ("hal_mtdservice_default", "hal_mtdservice_default_exec"),
        ("hal_mtkeysoter_default", "hal_mtkeysoter_default_exec"),
    ):
        assert f"(type {domain})" in policy
        assert f"(type {executable})" in policy
        assert (
            f"(typetransition init_${{API_VERSION}} {executable} process {domain})"
            in policy
        )

    assert "hal_allocator_default" not in policy
    assert "hal_allocator_default" not in (CONFIG_DIR / "mtd_file_contexts").read_text(
        encoding="utf-8"
    )
    overrides = (CONFIG_DIR / "exec_context_overrides.tsv").read_text(encoding="utf-8")
    for binary in ("/odm/bin/mtd", "/odm/bin/mtd_check", "/odm/bin/mtd_keysoter"):
        assert binary not in overrides


def test_aidl_and_runtime_data_contract() -> None:
    policy = POLICY.read_text(encoding="utf-8")
    assert "(allow hal_mtdservice_check self (qipcrtr_socket (create)))" in policy
    assert (
        "(allow hal_mtdservice_server hal_mtdservice_service "
        "(service_manager (add find)))"
    ) in policy
    assert (
        "(allow hal_mtkeysoter_default hal_mtkeysoter_service "
        "(service_manager (add find)))"
    ) in policy
    file_contexts = dict(active_context_records(CONFIG_DIR / "mtd_file_contexts"))
    odm_contexts = dict(active_context_records(CONFIG_DIR / "mtd_odm_contexts"))
    assert file_contexts["/data/vendor/images(/.*)?"] == "u:object_r:ta_data_file:s0"
    assert "/data/vendor/images(/.*)?" not in odm_contexts


if __name__ == "__main__":
    test_bundle_ownership_and_targets()
    test_requirements_are_owned_by_source_manifest()
    test_context_types_and_independent_domains()
    test_aidl_and_runtime_data_contract()
    print("fix_mi_account SELinux bundle tests passed")
