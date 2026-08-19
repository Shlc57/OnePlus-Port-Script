#!/usr/bin/env python3
"""Behavioural tests for the evidence-backed AVC policy patch."""

from __future__ import annotations

import importlib.util
from pathlib import Path


MODULE_PATH = Path(__file__).with_name("patch_vendor_avc_policy.py")
SPEC = importlib.util.spec_from_file_location("patch_vendor_avc_policy", MODULE_PATH)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


API = "202504"
VENDOR = """
(type vendor_location)
(type occe_create)
(type vendor_hal_qspmhal_default)
(typeattribute vendor_hal_qspmhal_client)
(type vendor_hal_qspmhal_service)
(type hal_nfc_default)
(type hal_graphics_composer_default)
(type vendor_smmu_proxy_device)
(type vendor_hal_poweroptservice_qti)
(type engineer_vendor_daemon)
(type mdm_feature)
(type vendor_logdump_partition)
(type vendor_bsg_device)
(type vendor_display_prop)
(allow surfaceflinger_202504 vendor_display_prop (file (read getattr map open)))
(allow system_server_202504 vendor_display_prop (file (read getattr map open)))
(allow system_app_202504 vendor_display_prop (file (read getattr map open)))
"""
PLATFORM = "(type hal_allocator_default)\n(type system_suspend)\n"
VERSIONED = """(type tee_device_202504)
(type servicemanager_202504)
(type init)
(type vendor_init)
(type bootanim)
(type surfaceflinger)
(type oppo_reserve_file)
"""
SYSTEM_EXT = "(type qsguard_exec)\n"


def test_patch_is_complete_and_idempotent() -> None:
    patched = MODULE.patch_policy(VENDOR, PLATFORM, VERSIONED, API, SYSTEM_EXT)
    assert patched.count(MODULE.BEGIN_MARKER) == 1
    assert len(MODULE.render_rules(API)) == 16
    assert len(MODULE.render_attribute_extensions()) == 1
    assert len(MODULE.render_statements(API)) == 17
    for statement in MODULE.render_statements(API):
        assert patched.count(statement) == 1
    assert "(allow vendor_init vendor_logdump_partition (lnk_file (setattr)))" in patched
    assert "(allow surfaceflinger vendor_hal_qspmhal_default (binder (call)))" in patched
    assert (
        "(typeattributeset vendor_hal_qspmhal_client "
        "(bootanim surfaceflinger occe_create))"
    ) in patched
    for forbidden_direct_allow in (
        "(allow bootanim vendor_hal_qspmhal_service (service_manager (find)))",
        "(allow surfaceflinger vendor_hal_qspmhal_service (service_manager (find)))",
        "(allow occe_create vendor_hal_qspmhal_service (service_manager (find)))",
    ):
        assert forbidden_direct_allow not in patched
    assert MODULE.patch_policy(patched, PLATFORM, VERSIONED, API, SYSTEM_EXT) == patched


def test_fragment_body_is_marker_free_for_unified_merge() -> None:
    fragment = MODULE.build_fragment_body(API)
    assert MODULE.BEGIN_MARKER not in fragment
    assert MODULE.END_MARKER not in fragment
    assert "${API_VERSION}" not in fragment
    for statement in MODULE.render_statements(API):
        assert fragment.count(statement) == 1


def test_unified_policy_accepts_extended_attribute_set() -> None:
    policy = (
        VENDOR
        + "\n"
        + "(typeattributeset vendor_hal_qspmhal_client "
        "(existing bootanim surfaceflinger occe_create))\n"
        + ";; BEGIN common/selinux_merge managed policy\n"
        + "\n".join(MODULE.render_rules(API))
        + "\n;; END common/selinux_merge managed policy\n"
    )
    assert MODULE.contains_typeattributeset_members(
        policy,
        "vendor_hal_qspmhal_client",
        ("bootanim", "surfaceflinger", "occe_create"),
    )


def test_old_managed_fragment_is_upgraded() -> None:
    current_rules = MODULE.render_rules(API)
    current_statements = MODULE.render_statements(API)
    unsafe_qspm_revision = [
        *current_rules[:15],
        "(allow bootanim vendor_hal_qspmhal_service (service_manager (find)))",
        current_rules[15],
        "(allow surfaceflinger vendor_hal_qspmhal_service (service_manager (find)))",
        "(allow occe_create vendor_hal_qspmhal_service (service_manager (find)))",
    ]
    # Exercise every managed revision that may already be present in a target:
    # the original eight/fourteen-rule fragments and the interim nineteen-rule
    # QSPM revision that violated the target policy's client-only neverallow.
    for legacy_statements in (
        current_rules[:8],
        current_rules[:14],
        unsafe_qspm_revision,
    ):
        old_fragment = "\n".join(
            [
                MODULE.BEGIN_MARKER,
                *legacy_statements,
                MODULE.END_MARKER,
            ]
        )
        old = VENDOR + "\n" + old_fragment + "\n"
        upgraded = MODULE.patch_policy(old, PLATFORM, VERSIONED, API, SYSTEM_EXT)
        assert upgraded.count(MODULE.BEGIN_MARKER) == 1
        assert upgraded.count(MODULE.END_MARKER) == 1
        for statement in current_statements:
            assert upgraded.count(statement) == 1
        for direct_find in unsafe_qspm_revision:
            if "vendor_hal_qspmhal_service (service_manager (find))" in direct_find:
                assert direct_find not in upgraded


def test_unmanaged_duplicate_is_rejected() -> None:
    for statement in (
        MODULE.render_rules(API)[0],
        MODULE.render_attribute_extensions()[0],
    ):
        duplicate = VENDOR + "\n" + statement + "\n"
        try:
            MODULE.patch_policy(duplicate, PLATFORM, VERSIONED, API, SYSTEM_EXT)
        except MODULE.PolicyError:
            continue
        raise AssertionError("unmanaged AVC statement was accepted")


def test_marker_errors_are_rejected() -> None:
    cases = (
        VENDOR + "\n" + MODULE.BEGIN_MARKER + "\n",
        VENDOR + "\n" + MODULE.BEGIN_MARKER + "\n" + MODULE.BEGIN_MARKER + "\n",
        VENDOR + "\n" + MODULE.END_MARKER + "\n" + MODULE.BEGIN_MARKER + "\n",
    )
    for case in cases:
        try:
            MODULE.patch_policy(case, PLATFORM, VERSIONED, API, SYSTEM_EXT)
        except MODULE.PolicyError:
            continue
        raise AssertionError("invalid managed marker block was accepted")


def test_missing_symbol_is_rejected() -> None:
    try:
        MODULE.patch_policy(VENDOR, "(type hal_allocator_default)\n", VERSIONED, API, SYSTEM_EXT)
    except MODULE.PolicyError as error:
        assert "system_suspend" in str(error)
    else:
        raise AssertionError("missing platform symbol was accepted")
    try:
        MODULE.patch_policy(VENDOR, PLATFORM, VERSIONED.replace("(type qsguard_exec)", ""), API, "")
    except MODULE.PolicyError as error:
        assert "qsguard_exec" in str(error)
    else:
        raise AssertionError("missing system_ext symbol was accepted")
    for missing, expected in (
        ("(type vendor_logdump_partition)\n", "vendor_logdump_partition"),
        (
            "(typeattribute vendor_hal_qspmhal_client)\n",
            "vendor_hal_qspmhal_client",
        ),
        ("(type vendor_hal_qspmhal_service)\n", "vendor_hal_qspmhal_service"),
    ):
        try:
            MODULE.patch_policy(VENDOR.replace(missing, ""), PLATFORM, VERSIONED, API, SYSTEM_EXT)
        except MODULE.PolicyError as error:
            assert expected in str(error)
        else:
            raise AssertionError(f"missing {expected} symbol was accepted")
    for missing, expected in (
        ("(type bootanim)\n", "bootanim"),
        ("(type surfaceflinger)\n", "surfaceflinger"),
    ):
        try:
            MODULE.patch_policy(VENDOR, PLATFORM, VERSIONED.replace(missing, ""), API, SYSTEM_EXT)
        except MODULE.PolicyError as error:
            assert expected in str(error)
        else:
            raise AssertionError(f"missing {expected} symbol was accepted")


def test_contexts_are_precise_and_idempotent() -> None:
    source = (
        "/dev/0:0:0:4 u:object_r:vendor_ufs_lun4_bsg_device:s0\n"
        "/dev/0:0:0:49476 u:object_r:vendor_bsg_device:s0\n"
        "/vendor/bin/qguard u:object_r:vendor_file:s0\n"
    )
    patched = MODULE.patch_contexts(source, VENDOR, SYSTEM_EXT)
    assert "/dev/0:0:0:[0-35] u:object_r:vendor_bsg_device:s0" in patched
    assert "/dev/0:0:0:4 u:object_r:vendor_ufs_lun4_bsg_device:s0" in patched
    assert "/dev/0:0:0:49476 u:object_r:vendor_bsg_device:s0" in patched
    assert "/vendor/bin/qguard u:object_r:qsguard_exec:s0" in patched
    assert MODULE.patch_contexts(patched, VENDOR, SYSTEM_EXT) == patched
    vendor_without_bsg = VENDOR.replace("(type vendor_bsg_device)\n", "")
    metadata = MODULE.patch_contexts(
        source,
        vendor_without_bsg,
        SYSTEM_EXT,
        include_device_nodes=False,
    )
    assert "/dev/0:0:0:[0-35]" not in metadata
    assert "/vendor/bin/qguard u:object_r:qsguard_exec:s0" in metadata


def test_escaped_context_path_is_replaced_without_duplication() -> None:
    source = (
        r"/dev/0\:0\:0\:[0-35] u:object_r:device:s0" + "\n"
        "/vendor/bin/qguard u:object_r:vendor_file:s0\n"
    )
    patched = MODULE.patch_contexts(source, VENDOR, SYSTEM_EXT)
    expected = r"/dev/0\:0\:0\:[0-35] u:object_r:vendor_bsg_device:s0"
    assert patched.count(expected) == 1
    assert "/dev/0:0:0:[0-35] u:object_r:vendor_bsg_device:s0" not in patched
    assert MODULE.patch_contexts(patched, VENDOR, SYSTEM_EXT) == patched


def test_context_duplicate_and_missing_symbols_fail() -> None:
    duplicate = "/vendor/bin/qguard u:object_r:vendor_file:s0\n/vendor/bin/qguard u:object_r:qsguard_exec:s0\n"
    try:
        MODULE.patch_contexts(duplicate, VENDOR, SYSTEM_EXT)
    except MODULE.PolicyError:
        pass
    else:
        raise AssertionError("duplicate active context was accepted")
    literal_bsg_duplicates = (
        "/dev/0:0:0:0 u:object_r:device:s0\n"
        "/dev/0:0:0:1 u:object_r:device:s0\n"
    )
    try:
        MODULE.patch_contexts(literal_bsg_duplicates, VENDOR, SYSTEM_EXT)
    except MODULE.PolicyError as error:
        assert "/dev/0:0:0:[0-35]" in str(error)
    else:
        raise AssertionError("multiple literal BSG context entries were accepted")
    try:
        MODULE.patch_contexts("", VENDOR.replace("(type vendor_bsg_device)", ""), SYSTEM_EXT)
    except MODULE.PolicyError as error:
        assert "vendor_bsg_device" in str(error)
    else:
        raise AssertionError("missing BSG type was accepted")
    try:
        MODULE.patch_contexts("", VENDOR, "")
    except MODULE.PolicyError as error:
        assert "qsguard_exec" in str(error)
    else:
        raise AssertionError("missing qguard type was accepted")


def test_property_contexts_are_precise_and_idempotent() -> None:
    source = (
        "ro.vendor. u:object_r:vendor_default_prop:s0\n"
        "persist.vendor. u:object_r:vendor_default_prop:s0\n"
        "vendor. u:object_r:vendor_default_prop:s0\n"
        "ro.vendor.display. u:object_r:vendor_display_prop:s0\n"
        "ro.vendor.mi_sf. u:object_r:vendor_default_prop:s0\n"
        "persist.vendor.disable_idle_fps u:object_r:vendor_default_prop:s0\n"
    )
    patched = MODULE.patch_property_contexts(source, VENDOR, API)
    for key, is_prefix in MODULE.PROPERTY_CONTEXT_RULES:
        match_operation = "prefix" if is_prefix else "exact"
        expected = f"{key} {MODULE.PROPERTY_CONTEXT_LABEL} {match_operation}"
        assert sum(line == expected for line in patched.splitlines()) == 1
    assert "ro.vendor. u:object_r:vendor_default_prop:s0" in patched
    assert "persist.vendor. u:object_r:vendor_default_prop:s0" in patched
    assert "vendor. u:object_r:vendor_default_prop:s0" in patched
    assert "ro.vendor.display. u:object_r:vendor_display_prop:s0" in patched
    assert MODULE.patch_property_contexts(patched, VENDOR, API) == patched


def test_property_context_conflicts_and_missing_policy_fail() -> None:
    conflict_cases = (
        (
            "ro.vendor.mi_sf. u:object_r:vendor_default_prop:s0\n"
            "ro.vendor.mi_sf.ltpo.support u:object_r:vendor_default_prop:s0\n"
        ),
        (
            "persist.vendor.disable_idle_fps.threshold "
            "u:object_r:vendor_default_prop:s0\n"
            "persist.vendor.disable_idle_fps.threshold "
            "u:object_r:vendor_display_prop:s0\n"
        ),
        (
            "ro.vendor.mi_sf. u:object_r:vendor_default_prop:s0\n"
            "ro.vendor.mi_sf. u:object_r:vendor_display_prop:s0\n"
        ),
    )
    for conflict in conflict_cases:
        try:
            MODULE.patch_property_contexts(conflict, VENDOR, API)
        except MODULE.PolicyError:
            continue
        raise AssertionError("conflicting property context was accepted")

    for missing_policy, expected in (
        (
            VENDOR.replace("(type vendor_display_prop)\n", ""),
            "vendor_display_prop",
        ),
        (
            VENDOR.replace(
                "(allow surfaceflinger_202504 vendor_display_prop "
                "(file (read getattr map open)))\n",
                "",
            ),
            "file",
        ),
        (
            VENDOR.replace(
                "(allow system_app_202504 vendor_display_prop "
                "(file (read getattr map open)))\n",
                "",
            ),
            "system_app_202504",
        ),
    ):
        try:
            MODULE.patch_property_contexts("", missing_policy, API)
        except MODULE.PolicyError as error:
            assert expected in str(error)
        else:
            raise AssertionError("missing property policy contract was accepted")


def test_no_broad_vendor_default_prop_allow_is_generated() -> None:
    patched = MODULE.patch_policy(VENDOR, PLATFORM, VERSIONED, API, SYSTEM_EXT)
    forbidden_targets = (
        "surfaceflinger",
        "system_server",
        "system_app",
    )
    for domain in forbidden_targets:
        assert f"(allow {domain} vendor_default_prop" not in patched


if __name__ == "__main__":
    test_patch_is_complete_and_idempotent()
    test_fragment_body_is_marker_free_for_unified_merge()
    test_unified_policy_accepts_extended_attribute_set()
    test_old_managed_fragment_is_upgraded()
    test_unmanaged_duplicate_is_rejected()
    test_marker_errors_are_rejected()
    test_missing_symbol_is_rejected()
    test_contexts_are_precise_and_idempotent()
    test_escaped_context_path_is_replaced_without_duplication()
    test_context_duplicate_and_missing_symbols_fail()
    test_property_contexts_are_precise_and_idempotent()
    test_property_context_conflicts_and_missing_policy_fail()
    test_no_broad_vendor_default_prop_allow_is_generated()
    print("patch_vendor_avc_policy tests passed")
