#!/usr/bin/env python3
"""Behavioural tests for the unified SELinux merge interface."""

from __future__ import annotations

import tempfile
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
import selinux_merge as merger


def test_cil_merge_keeps_target_genfscon() -> None:
    target = """(type target_domain)
(typeattributeset base_typeattr_1_202504 (domain))
(typeattributeset shared_attr (target_domain))
(genfscon proc \"/same\" (u object_r target_proc ((s0) (s0))))
"""
    source = """(type source_domain)
(typeattributeset base_typeattr_1_202504 (domain))
(typeattributeset shared_attr (source_domain))
(genfscon proc \"/same\" (u object_r source_proc ((s0) (s0))))
(genfscon proc \"/source\" (u object_r source_proc ((s0) (s0))))
"""
    merged, added, conflicts, attrs = merger.merge_cil(target, source)
    assert "(type source_domain)" in merged
    assert "(typeattributeset shared_attr (target_domain source_domain))" in merged
    assert "target_proc" in merged and "source_proc" not in merged.split('(genfscon proc \"/same\"', 1)[1].split("\n", 1)[0]
    assert added == 2
    assert conflicts == 1
    assert attrs == 1
    rerun, rerun_added, rerun_conflicts, rerun_attrs = merger.merge_cil(merged, source)
    assert rerun == merged
    assert rerun_added == 0
    assert rerun_conflicts == 1
    assert rerun_attrs == 1


def test_cil_merge_rejects_incompatible_base_typeattr() -> None:
    target = "(typeattributeset base_typeattr_1_202504 (domain))\n"
    source = "(typeattributeset base_typeattr_1_202504 (appdomain))\n"
    try:
        merger.merge_cil(target, source)
    except merger.MergeError as error:
        assert "base_typeattr ABI 不兼容" in str(error)
    else:
        raise AssertionError("expected an incompatible base_typeattr error")


def test_cil_merge_rejects_conflicting_source_keys() -> None:
    target = """(type target_domain)
(typeattribute shared_attr)
(typeattributeset base_typeattr_1_202504 (domain))
"""
    source = """(type source_domain_a)
(type source_domain_b)
(typeattributeset base_typeattr_1_202504 (domain))
(typeattributeset shared_attr (source_domain_a))
(typeattributeset shared_attr (source_domain_b))
"""
    try:
        merger.merge_cil(target, source)
    except merger.MergeError as error:
        assert "原包 CIL 内部存在冲突的策略键" in str(error)
    else:
        raise AssertionError("expected conflicting source keys to fail")


def test_context_merge_keeps_target_service_label() -> None:
    target = "service.default u:object_r:target_service:s0\n"
    source = "service.default u:object_r:source_service:s0\nservice.extra u:object_r:extra_service:s0\n"
    merged, added, conflicts, unavailable = merger.merge_contexts(
        target,
        source,
        "vendor_service_contexts",
    )
    assert "target_service" in merged
    assert "source_service" not in merged
    assert "service.extra u:object_r:extra_service:s0" in merged
    assert (added, conflicts, unavailable) == (1, 1, 0)


def test_context_merge_collapses_old_and_new_markers() -> None:
    target = (
        "service.base u:object_r:base_service:s0\n"
        f"{merger.LEGACY_CONTEXT_BEGIN_MARKER}\n"
        "# legacy note\n\n"
        "service.legacy u:object_r:legacy_service:s0\n"
        f"{merger.LEGACY_CONTEXT_END_MARKER}\n"
        f"{merger.CONTEXT_BEGIN_MARKER}\n"
        "service.current u:object_r:current_service:s0\n"
        f"{merger.CONTEXT_END_MARKER}\n"
    )
    merged, added, conflicts, unavailable = merger.merge_contexts(
        target,
        "service.new u:object_r:new_service:s0\n",
        "vendor_service_contexts",
    )
    assert merged.count(merger.CONTEXT_BEGIN_MARKER) == 1
    assert merger.LEGACY_CONTEXT_BEGIN_MARKER not in merged
    assert "# legacy note" in merged
    for service in ("legacy_service", "current_service", "new_service"):
        assert service in merged
    assert (added, conflicts, unavailable) == (1, 0, 0)


def test_context_merge_matches_escaped_path_spellings() -> None:
    target = r"/vendor/bin/foo u:object_r:target_exec:s0" + "\n"
    source = "/vendor/bin/foo u:object_r:source_exec:s0\n"
    merged, added, conflicts, unavailable = merger.merge_contexts(
        target,
        source,
        "vendor_file_contexts",
    )
    assert merged == target
    assert (added, conflicts, unavailable) == (0, 1, 0)
    source_new = r"/vendor/bin/new\:foo u:object_r:new_exec:s0" + "\n"
    merged_new, _, _, _ = merger.merge_contexts(
        target,
        source_new,
        "vendor_file_contexts",
    )
    assert r"/vendor/bin/new\:foo u:object_r:new_exec:s0" in merged_new


def test_context_normalization_places_managed_block_last() -> None:
    target = (
        "service.base u:object_r:base_service:s0\n"
        f"{merger.CONTEXT_BEGIN_MARKER}\n"
        "service.imported u:object_r:imported_service:s0\n"
        f"{merger.CONTEXT_END_MARKER}\n"
        "service.patch u:object_r:patch_service:s0\n"
    )
    normalized = merger.normalize_managed_contexts(
        target,
        "vendor_service_contexts",
    )
    assert normalized.index("service.patch") < normalized.index(
        merger.CONTEXT_BEGIN_MARKER
    )
    assert normalized.endswith(f"{merger.CONTEXT_END_MARKER}\n")
    assert (
        merger.normalize_managed_contexts(normalized, "vendor_service_contexts")
        == normalized
    )


def test_seapp_fallback_checks_domain_and_selector_conflicts() -> None:
    target = (
        "user=_app seinfo=platform name=com.example.same "
        "domain=known_domain type=known_data levelFrom=all\n"
    )
    source = (
        "user=_app seinfo=platform name=com.example.same "
        "domain=other_known_domain type=known_data levelFrom=all\n"
        "user=_app seinfo=platform name=com.example.unknown "
        "domain=missing_domain type=known_data levelFrom=all\n"
    )
    merged, added, conflicts, unavailable = merger.merge_contexts(
        target,
        source,
        "vendor_seapp_contexts",
        {"known_domain", "other_known_domain", "known_data"},
    )
    assert merged == target
    assert (added, conflicts, unavailable) == (0, 1, 1)


def test_incompatible_cil_uses_existing_type_context_fallback() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        target = root / "target"
        source = root / "source"
        output = root / "output"
        target.mkdir()
        source.mkdir()
        (target / "vendor_sepolicy.cil").write_text(
            "(type target_domain)\n"
            "(type known_file)\n"
            "(typeattributeset base_typeattr_1_202504 (domain))\n",
            encoding="utf-8",
        )
        (source / "vendor_sepolicy.cil").write_text(
            "(type source_domain)\n"
            "(type unknown_file)\n"
            "(typeattributeset base_typeattr_1_202504 (appdomain))\n",
            encoding="utf-8",
        )
        (target / "vendor_file_contexts").write_text(
            "/vendor/target u:object_r:known_file:s0\n", encoding="utf-8"
        )
        (source / "vendor_file_contexts").write_text(
            "/vendor/known u:object_r:known_file:s0\n"
            "/vendor/unknown u:object_r:unknown_file:s0\n",
            encoding="utf-8",
        )
        for directory in (target, source):
            (directory / "plat_sepolicy_vers.txt").write_text(
                "202504\n", encoding="utf-8"
            )
            (directory / "genfs_labels_version.txt").write_text(
                "1\n", encoding="utf-8"
            )
        merger.merge_directories(target, source, output)
        assert not (output / "vendor_sepolicy.cil").exists()
        merged_contexts = (output / "vendor_file_contexts").read_text(encoding="utf-8")
        assert "/vendor/known" in merged_contexts
        assert "/vendor/unknown" not in merged_contexts


def test_incompatible_fallback_ignores_patch_owned_types() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        target = root / "target"
        source = root / "source"
        output = root / "output"
        target.mkdir()
        source.mkdir()
        (target / "vendor_sepolicy.cil").write_text(
            "(type native_file)\n"
            "(typeattributeset base_typeattr_1_202504 (domain))\n"
            f"{merger.POLICY_BEGIN_MARKER}\n"
            "(type patch_owned_file)\n"
            f"{merger.POLICY_END_MARKER}\n",
            encoding="utf-8",
        )
        (source / "vendor_sepolicy.cil").write_text(
            "(type source_domain)\n"
            "(typeattributeset base_typeattr_1_202504 (appdomain))\n",
            encoding="utf-8",
        )
        (target / "vendor_file_contexts").write_text(
            "/vendor/native u:object_r:native_file:s0\n", encoding="utf-8"
        )
        (source / "vendor_file_contexts").write_text(
            "/vendor/from-source u:object_r:patch_owned_file:s0\n",
            encoding="utf-8",
        )
        for directory in (target, source):
            (directory / "plat_sepolicy_vers.txt").write_text(
                "202504\n", encoding="utf-8"
            )
            (directory / "genfs_labels_version.txt").write_text(
                "1\n", encoding="utf-8"
            )
        merger.merge_directories(target, source, output)
        merged_contexts = (output / "vendor_file_contexts").read_text(
            encoding="utf-8"
        )
        assert "/vendor/from-source" not in merged_contexts


def test_directory_merge_writes_expected_files() -> None:
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        target = root / "target"
        source = root / "source"
        output = root / "output"
        target.mkdir()
        source.mkdir()
        (target / "vendor_sepolicy.cil").write_text(
            "(type target_domain)\n(typeattributeset base_typeattr_1_202504 (domain))\n",
            encoding="utf-8",
        )
        (source / "vendor_sepolicy.cil").write_text(
            "(type source_domain)\n(typeattributeset base_typeattr_1_202504 (domain))\n",
            encoding="utf-8",
        )
        for directory in (target, source):
            (directory / "plat_sepolicy_vers.txt").write_text(
                "202504\n", encoding="utf-8"
            )
            (directory / "genfs_labels_version.txt").write_text(
                "1\n", encoding="utf-8"
            )
        (target / "vendor_service_contexts").write_text(
            "service.target u:object_r:target_service:s0\n", encoding="utf-8"
        )
        (source / "vendor_service_contexts").write_text(
            "service.source u:object_r:source_service:s0\n", encoding="utf-8"
        )
        merger.merge_directories(target, source, output)
        assert "source_domain" in (output / "vendor_sepolicy.cil").read_text(encoding="utf-8")
        assert "service.source" in (output / "vendor_service_contexts").read_text(encoding="utf-8")


def test_policy_fragments_share_one_managed_block_and_expand_api() -> None:
    target = """(typeattributeset vendor_hal_display_color_client (platform_app))
;; BEGIN common/fix_vendor_avc evidence-backed rules
(allow old_domain old_type (file (read)))
;; END common/fix_vendor_avc evidence-backed rules
"""
    avc = "(allow ${API_VERSION}_domain target_type (file (read)))\n"
    display = """(allow servicemanager_${API_VERSION} display_server (binder (call)))
(typeattributeset vendor_hal_display_color_client (system_server_${API_VERSION}))
"""
    merged, added, conflicts, attrs = merger.merge_policy_fragments(
        target, [avc, display], "202504"
    )
    assert merger.POLICY_BEGIN_MARKER in merged
    assert merger.LEGACY_AVC_BEGIN_MARKER not in merged
    assert merged.count(merger.POLICY_BEGIN_MARKER) == 1
    assert "202504_domain" in merged
    assert "system_server_202504" in merged
    assert "platform_app system_server_202504" in merged
    assert added == 2
    assert conflicts == 0
    assert attrs == 1
    rerun, rerun_added, _, _ = merger.merge_policy_fragments(
        merged, [avc, display], "202504"
    )
    assert rerun == merged
    assert rerun_added == 0


def test_policy_fragment_rejects_unresolved_variable() -> None:
    try:
        merger.merge_policy_fragments("", ["(type ${UNKNOWN})"], "202504")
    except merger.MergeError as error:
        assert "未支持的变量" in str(error)
    else:
        raise AssertionError("expected unresolved variable to fail")


def test_policy_fragment_can_replace_legacy_provider_block() -> None:
    target = (
        "(type old_domain)\n"
        f"{merger.LEGACY_AVC_BEGIN_MARKER}\n"
        "(allow old_domain old_type (file (read)))\n"
        f"{merger.LEGACY_AVC_END_MARKER}\n"
    )
    replacement = "(allow old_domain new_type (file (write)))\n"
    merged, _, _, _ = merger.merge_policy_fragments(
        target,
        [replacement],
        "202504",
        ((merger.LEGACY_AVC_BEGIN_MARKER, merger.LEGACY_AVC_END_MARKER),),
    )
    assert "old_type" not in merged
    assert "new_type" in merged


def make_merge_dirs(root: Path, target_version: str, source_version: str | None) -> tuple:
    target = root / "target"
    source = root / "source"
    output = root / "output"
    target.mkdir()
    source.mkdir()
    (target / "vendor_sepolicy.cil").write_text(
        "(type target_domain)\n(typeattributeset base_typeattr_1_202404 (domain))\n",
        encoding="utf-8",
    )
    (source / "vendor_sepolicy.cil").write_text(
        "(type source_domain)\n(typeattributeset base_typeattr_1_202504 (domain))\n",
        encoding="utf-8",
    )
    for directory, version in ((target, target_version), (source, source_version)):
        if version is None:
            continue
        (directory / "plat_sepolicy_vers.txt").write_text(version + "\n", encoding="utf-8")
        (directory / "genfs_labels_version.txt").write_text("1\n", encoding="utf-8")
    (target / "vendor_service_contexts").write_text(
        "service.kept u:object_r:target_service:s0\n", encoding="utf-8"
    )
    (source / "vendor_service_contexts").write_text(
        "service.kept u:object_r:target_service:s0\n"
        "service.new u:object_r:source_service:s0\n",
        encoding="utf-8",
    )
    return target, source, output


def test_cross_generation_marker_mismatch_downgrades() -> None:
    """跨代（Android15 底包 + Android16 原包）不得硬拒：保底包基线 CIL，只并底包已有类型可承载的 contexts。"""
    with tempfile.TemporaryDirectory() as temporary:
        target, source, output = make_merge_dirs(Path(temporary), "202404", "202504")
        merger.merge_directories(target, source, output)
        # 不写合并后的 CIL，下游 merged_or_target 会回退到底包自己的策略
        assert not (output / "vendor_sepolicy.cil").exists()
        merged = (output / "vendor_service_contexts").read_text(encoding="utf-8")
        assert "service.kept" in merged
        assert "service.new" not in merged


def test_missing_source_marker_also_downgrades() -> None:
    """原包没有版本标记时同样走降级，不能当硬错误拦住整套移植。"""
    with tempfile.TemporaryDirectory() as temporary:
        target, source, output = make_merge_dirs(Path(temporary), "202404", None)
        merger.merge_directories(target, source, output)
        assert not (output / "vendor_sepolicy.cil").exists()


def test_bottom_side_version_marker_is_still_required() -> None:
    """底包缺版本标记仍必须失败：基线不能猜。"""
    with tempfile.TemporaryDirectory() as temporary:
        root = Path(temporary)
        target, source, output = make_merge_dirs(root, "202404", "202404")
        (target / "plat_sepolicy_vers.txt").unlink()
        try:
            merger.merge_directories(target, source, output)
        except merger.MergeError as error:
            assert "plat_sepolicy_vers.txt" in str(error)
        else:
            raise AssertionError("expected missing bottom version marker to fail")


def test_target_escape_duplicate_entries_are_tolerated() -> None:
    """底包同一规则的转义/未转义写法只能算重复，不能拦住合并；标签不同仍致命。"""
    escaped = "/sys/soc/a\\.b/i2c-1/ufcs u:object_r:sysfs_wakeup:s0\n"
    plain = "/sys/soc/a.b/i2c-1/ufcs u:object_r:sysfs_wakeup:s0\n"
    merged, added, conflicts, unavailable = merger.merge_contexts(
        escaped + plain, "", "vendor_file_contexts", None
    )
    # 不再报致命冲突；底包两行保持原形（我们不重写底包文件），但不能因此把来源条目再插一条
    assert added == 0
    assert conflicts == 0 and unavailable == 0
    assert len([line for line in merged.splitlines() if line.strip()]) == 2
    other_label = "/sys/soc/a.b/i2c-1/ufcs u:object_r:sysfs_other:s0\n"
    try:
        merger.merge_contexts(escaped + other_label, "", "vendor_file_contexts", None)
    except merger.MergeError as error:
        assert "存在冲突条目" in str(error)
    else:
        raise AssertionError("expected differing labels under one key to fail")


if __name__ == "__main__":
    test_cil_merge_keeps_target_genfscon()
    test_cil_merge_rejects_incompatible_base_typeattr()
    test_cil_merge_rejects_conflicting_source_keys()
    test_context_merge_keeps_target_service_label()
    test_context_merge_collapses_old_and_new_markers()
    test_context_merge_matches_escaped_path_spellings()
    test_context_normalization_places_managed_block_last()
    test_seapp_fallback_checks_domain_and_selector_conflicts()
    test_incompatible_cil_uses_existing_type_context_fallback()
    test_incompatible_fallback_ignores_patch_owned_types()
    test_directory_merge_writes_expected_files()
    test_policy_fragments_share_one_managed_block_and_expand_api()
    test_policy_fragment_rejects_unresolved_variable()
    test_policy_fragment_can_replace_legacy_provider_block()
    test_bottom_side_version_marker_is_still_required()
    test_cross_generation_marker_mismatch_downgrades()
    test_missing_source_marker_also_downgrades()
    test_target_escape_duplicate_entries_are_tolerated()
    print("selinux_merge tests passed")
