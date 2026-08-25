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
        "odm/bin/idmanager",
        "odm/bin/mtd",
        "odm/bin/mtd_check",
        "odm/bin/mtd_keysoter",
        "odm/etc/init/vendor.xiaomi.hardware.idmanager.rc",
        "odm/etc/init/vendor.xiaomi.hardware.aidl.mtdservice-service.rc",
        "odm/etc/init/vendor.xiaomi.hardware.aidl.mtd_check-service.rc",
        "odm/etc/init/vendor.xiaomi.hardware.aidl.mtkeysoter-service.rc",
        "odm/etc/vintf/manifest/vendor.xiaomi.hardware.idmanager.xml",
        "odm/lib64/libidprovision.so",
        "odm/lib64/libsecid.so",
        "odm/lib64/vendor.xiaomi.hardware.idmanager-V1-ndk.so",
        "vendor/lib64/hw/libEseUtils.so",
        "vendor/lib64/libQSEEComAPI.so",
        "vendor/lib64/libminkdescriptor.so",
        "vendor/lib64/libprovisioner_qti.so",
        "vendor/lib64/vendor.xiaomi.hardware.misys.core-V1-ndk.so",
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
        ("vendor_file_contexts", "config/idmanager_file_contexts"),
        ("precompiled_file_contexts", "config/idmanager_file_contexts"),
        ("odm_metadata_contexts", "config/idmanager_file_contexts"),
        ("vendor_property_contexts", "config/idmanager_property_contexts"),
        ("precompiled_property_contexts", "config/idmanager_property_contexts"),
        ("vendor_service_contexts", "config/idmanager_service_contexts"),
        ("precompiled_service_contexts", "config/idmanager_service_contexts"),
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
        ("hal_idmanager_default", "hal_idmanager_default_exec"),
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
    for binary in (
        "/odm/bin/mtd",
        "/odm/bin/mtd_check",
        "/odm/bin/mtd_keysoter",
        "/odm/bin/idmanager",
    ):
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


def test_device_identifier_property_contract() -> None:
    policy = POLICY.read_text(encoding="utf-8")
    property_contexts = dict(
        active_context_records(CONFIG_DIR / "mtd_property_contexts")
    )
    expected_keys = {
        "persist.vendor.radio.imei",
        "ro.vendor.oem.imei",
        "persist.vendor.radio.meid",
        "ro.vendor.oem.meid",
        "persist.vendor.eid.record",
    }
    assert {
        key
        for key, context in property_contexts.items()
        if key in expected_keys and context == "u:object_r:vendor_deviceid_prop:s0"
    } == expected_keys
    assert (
        "(allow rild vendor_deviceid_prop (file (read getattr map open)))" in policy
    )
    assert "(allow rild vendor_deviceid_prop (property_service (set)))" in policy
    assert "persist.vendor.radio. u:object_r:vendor_deviceid_prop:s0" not in (
        CONFIG_DIR / "mtd_property_contexts"
    ).read_text(encoding="utf-8")


def test_idmanager_contract() -> None:
    policy = POLICY.read_text(encoding="utf-8")
    file_contexts = dict(active_context_records(CONFIG_DIR / "idmanager_file_contexts"))
    property_contexts = dict(
        active_context_records(CONFIG_DIR / "idmanager_property_contexts")
    )
    service_contexts = dict(
        active_context_records(CONFIG_DIR / "idmanager_service_contexts")
    )
    assert file_contexts["/odm/bin/idmanager"] == (
        "u:object_r:hal_idmanager_default_exec:s0"
    )
    assert property_contexts["ro.vendor.oem.sno"] == (
        "u:object_r:vendor_sno_prop:s0"
    )
    assert property_contexts["ro.vendor.oem.psno"] == (
        "u:object_r:vendor_sno_prop:s0"
    )
    assert service_contexts[
        "vendor.xiaomi.hardware.idmanager.IIdManagerService/default"
    ] == "u:object_r:hal_idmanager_service:s0"
    assert service_contexts[
        "vendor.xiaomi.hardware.idmanager.ISecidService/default"
    ] == "u:object_r:hal_idmanager_service:s0"
    assert "(type hal_idmanager_default)" in policy
    assert "(type hal_idmanager_default_exec)" in policy
    assert "(type hal_idmanager_service)" in policy
    assert "(type vendor_sno_prop)" in policy
    # The source policy also has an unbound legacy `idmanager` coredomain.
    # It has no executable, init service, or context consumer, so it must not
    # be conflated with /odm/bin/idmanager's HAL server domain.
    assert "(type idmanager)" not in policy
    assert "(allow idmanager servicemanager_${API_VERSION}" not in policy
    assert "(expandtypeattribute (hal_idmanager) true)" in policy
    assert re.search(
        r"\(typeattributeset hal_secure_element_client \([^)]*\bhal_idmanager_default\b[^)]*\)\)",
        policy,
    )
    assert (
        "(typetransition init_${API_VERSION} hal_idmanager_default_exec "
        "process hal_idmanager_default)"
    ) in policy
    assert (
        "(typeattributeset hal_idmanager_client "
        "(platform_app_${API_VERSION} system_app_${API_VERSION} "
        "hal_mtdservice_default))"
    ) in policy
    assert "hal_misyscore_default" not in policy
    assert "hal_misyscore_service" not in policy
    assert "secinfo_block_device" not in policy

    bundle_text = BUNDLE.read_text(encoding="utf-8")
    assert "vendor.xiaomi.hardware.misys.core-service" not in bundle_text
    assert "/dev/block/by-name/secinfo" not in bundle_text
    assert "vendor/lib64/vendor.xiaomi.hardware.misys.core-V1-ndk.so" in bundle_text

    vendor_sources = (CONFIG_DIR / "mi_vendor_sources.tsv").read_text(
        encoding="utf-8"
    )
    assert "bin/hw/vendor.xiaomi.hardware.misys.core-service" not in vendor_sources
    assert "etc/init/vendor.xiaomi.hardware.misys.core-service.rc" not in vendor_sources
    assert "etc/vintf/manifest/vendor.xiaomi.hardware.misys.core.xml" not in vendor_sources
    assert "lib64/vendor.xiaomi.hardware.misys.core-V1-ndk.so" in vendor_sources


if __name__ == "__main__":
    test_bundle_ownership_and_targets()
    test_requirements_are_owned_by_source_manifest()
    test_context_types_and_independent_domains()
    test_aidl_and_runtime_data_contract()
    test_device_identifier_property_contract()
    test_idmanager_contract()
    print("fix_mi_account SELinux bundle tests passed")
