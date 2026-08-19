#!/usr/bin/env python3
"""Patch evidence-backed vendor SELinux rules and runtime contexts."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


BEGIN_MARKER = ";; BEGIN common/fix_vendor_avc evidence-backed rules"
END_MARKER = ";; END common/fix_vendor_avc evidence-backed rules"
UNIFIED_BEGIN_MARKER = ";; BEGIN common/selinux_merge managed policy"
UNIFIED_END_MARKER = ";; END common/selinux_merge managed policy"

# These are deliberately narrow labels.  In particular, the UFS nodes are
# not given the generic ``device`` type and LUN4 is kept on its existing
# dedicated label by the character class below.
CONTEXT_OVERRIDES = (
    ("/dev/0:0:0:[0-35]", "u:object_r:vendor_bsg_device:s0"),
    ("/vendor/bin/qguard", "u:object_r:qsguard_exec:s0"),
)
# Xiaomi's source policy labels these refresh-rate properties with display
# types that do not exist in the target vendor policy.  Relabel only the
# observed MI-SF/DFPS namespaces to the target's existing vendor display type;
# adding direct access to vendor_default_prop would violate the platform
# neverallow during split-policy compilation.
PROPERTY_CONTEXT_LABEL = "u:object_r:vendor_display_prop:s0"
PROPERTY_CONTEXT_RULES = (
    ("ro.vendor.mi_sf.", True),
    ("vendor.mi_sf.", True),
    ("persist.vendor.mi_sf.", True),
    ("ro.vendor.fps.", True),
    ("ro.vendor.dfps.", True),
    ("persist.vendor.dfps.", True),
    ("persist.vendor.disable_idle_fps", False),
    ("persist.vendor.disable_idle_fps.threshold", False),
)


class PolicyError(ValueError):
    """Raised when the target policy is not safe to patch deterministically."""


def render_rules(api_version: str) -> list[str]:
    return [
        f"(allow hal_allocator_default tee_device_{api_version} (chr_file (ioctl read write open)))",
        f"(allow hal_allocator_default servicemanager_{api_version} (binder (call transfer)))",
        "(allow hal_allocator_default hal_allocator_default (qipcrtr_socket (create)))",
        "(allow vendor_location vendor_location (qipcrtr_socket (create getattr read write)))",
        f"(allow occe_create servicemanager_{api_version} (binder (call)))",
        "(allow occe_create vendor_hal_qspmhal_default (binder (call)))",
        "(allow hal_nfc_default system_suspend (binder (call)))",
        "(allow system_suspend hal_nfc_default (binder (transfer)))",
        "(allow hal_graphics_composer_default vendor_smmu_proxy_device (chr_file (read)))",
        f"(allow servicemanager_{api_version} vendor_hal_poweroptservice_qti (binder (call)))",
        "(allow init oppo_reserve_file (dir (getattr)))",
        "(allow vendor_init oppo_reserve_file (dir (search getattr setattr)))",
        "(allow engineer_vendor_daemon oppo_reserve_file (dir (search)))",
        "(allow mdm_feature oppo_reserve_file (dir (search)))",
        # rawdump is a symlink under /dev/block; vendor_init only needs the
        # setattr used by the init.qcom.rc chown/chmod actions.
        "(allow vendor_init vendor_logdump_partition (lnk_file (setattr)))",
        # QSPM client membership below supplies the canonical Binder contract;
        # retain this evidence-backed direct call without broadening its class.
        "(allow surfaceflinger vendor_hal_qspmhal_default (binder (call)))",
    ]


def render_attribute_extensions() -> list[str]:
    # The vendor policy's neverallow permits service lookup only to members of
    # vendor_hal_qspmhal_client.  Use that existing HAL contract for the three
    # callers observed in logcat instead of bypassing it with direct allows.
    return [
        "(typeattributeset vendor_hal_qspmhal_client (bootanim surfaceflinger occe_create))"
    ]


def render_statements(api_version: str) -> list[str]:
    return [*render_rules(api_version), *render_attribute_extensions()]


def contains_symbol(policy: str, symbol: str) -> bool:
    return re.search(
        rf"(?<![A-Za-z0-9_]){re.escape(symbol)}(?![A-Za-z0-9_])", policy
    ) is not None


def contains_cil_statement(policy: str, statement: str) -> bool:
    """Match one CIL statement while allowing harmless whitespace changes."""

    tokens = re.split(r"\s+", statement.strip())
    pattern = r"\s+".join(re.escape(token) for token in tokens)
    return re.search(pattern, policy) is not None


def contains_typeattributeset_members(
    policy: str,
    attribute: str,
    required_members: tuple[str, ...],
) -> bool:
    """Check membership without requiring the target's other members/order."""

    match = re.search(
        rf"\(typeattributeset\s+{re.escape(attribute)}\s+\(([^()]*)\)\)",
        policy,
    )
    if match is None:
        return False
    members = set(match.group(1).split())
    return set(required_members).issubset(members)


def validate_property_context_policy(policy: str, api_version: str) -> None:
    property_type = "vendor_display_prop"
    if not contains_cil_statement(policy, f"(type {property_type})"):
        raise PolicyError(f"目标 vendor CIL 缺少属性标签类型：{property_type}")

    versioned_domains = (
        f"surfaceflinger_{api_version}",
        f"system_server_{api_version}",
        f"system_app_{api_version}",
    )
    required_statements = tuple(
        f"(allow {domain} {property_type} "
        "(file (read getattr map open)))"
        for domain in versioned_domains
    )
    for statement in required_statements:
        if not contains_cil_statement(policy, statement):
            raise PolicyError(f"目标 vendor CIL 缺少属性标签配套权限：{statement}")


def validate_symbols(
    policy: str,
    platform_policy: str,
    versioned_policy: str,
    api_version: str,
    system_ext_policy: str = "",
) -> None:
    for symbol in (
        "vendor_location",
        "occe_create",
        "vendor_hal_qspmhal_default",
        "vendor_hal_qspmhal_client",
        "vendor_hal_qspmhal_service",
        "hal_nfc_default",
        "hal_graphics_composer_default",
        "vendor_smmu_proxy_device",
        "vendor_hal_poweroptservice_qti",
        "engineer_vendor_daemon",
        "mdm_feature",
        "vendor_logdump_partition",
    ):
        if not contains_symbol(policy, symbol):
            raise PolicyError(f"目标 vendor CIL 缺少 AVC 规则所需类型：{symbol}")

    if not contains_symbol(platform_policy, "hal_allocator_default"):
        raise PolicyError("plat_sepolicy.cil 缺少 hal_allocator_default")
    if not contains_symbol(platform_policy, "system_suspend"):
        raise PolicyError("plat_sepolicy.cil 缺少 system_suspend")
    for symbol in (
        f"tee_device_{api_version}",
        f"servicemanager_{api_version}",
        "init",
        "vendor_init",
        "bootanim",
        "surfaceflinger",
        "oppo_reserve_file",
    ):
        if not contains_symbol(versioned_policy, symbol):
            raise PolicyError(f"plat_pub_versioned.cil 缺少当前 API 类型：{symbol}")
    if not contains_symbol(system_ext_policy, "qsguard_exec"):
        raise PolicyError("system_ext_sepolicy.cil 缺少 qsguard_exec")


def build_fragment(api_version: str) -> str:
    return "\n".join([BEGIN_MARKER, *render_statements(api_version), END_MARKER])


def build_fragment_body(api_version: str) -> str:
    """Return only this patch's statements for the unified merge interface."""

    return "\n".join(render_statements(api_version)) + "\n"


def _marker_lines(policy: str, marker: str) -> list[int]:
    """Return marker line indexes, ignoring marker text in other comments."""

    return [
        index
        for index, line in enumerate(policy.splitlines())
        if line == marker
    ]


def _replace_managed_fragment(policy: str, fragment: str) -> str:
    """Replace one complete managed block, including an older rule revision."""

    lines = policy.splitlines(keepends=True)
    begin_indexes = [
        index for index, line in enumerate(lines) if line.rstrip("\r\n") == BEGIN_MARKER
    ]
    end_indexes = [
        index for index, line in enumerate(lines) if line.rstrip("\r\n") == END_MARKER
    ]
    if not begin_indexes and not end_indexes:
        return policy.rstrip("\n") + "\n\n" + fragment + "\n"
    if len(begin_indexes) != 1 or len(end_indexes) != 1:
        raise PolicyError("AVC 补丁边界标记不完整或重复")
    begin_index = begin_indexes[0]
    end_index = end_indexes[0]
    if end_index < begin_index:
        raise PolicyError("AVC 补丁边界标记顺序错误")
    prefix = "".join(lines[:begin_index])
    suffix = "".join(lines[end_index + 1 :])
    if prefix and not prefix.endswith("\n"):
        prefix += "\n"
    return prefix + fragment + "\n" + suffix


def patch_policy(
    policy: str,
    platform_policy: str,
    versioned_policy: str,
    api_version: str,
    system_ext_policy: str = "",
) -> str:
    validate_symbols(
        policy,
        platform_policy,
        versioned_policy,
        api_version,
        system_ext_policy,
    )
    fragment = build_fragment(api_version)
    begin_indexes = _marker_lines(policy, BEGIN_MARKER)
    end_indexes = _marker_lines(policy, END_MARKER)
    if not begin_indexes and not end_indexes:
        unified_begin_indexes = _marker_lines(policy, UNIFIED_BEGIN_MARKER)
        unified_end_indexes = _marker_lines(policy, UNIFIED_END_MARKER)
        if unified_begin_indexes or unified_end_indexes:
            if len(unified_begin_indexes) != 1 or len(unified_end_indexes) != 1:
                raise PolicyError("统一 SELinux policy 边界标记不完整或重复")
            missing = [
                statement
                for statement in render_rules(api_version)
                if not contains_cil_statement(policy, statement)
            ]
            if not contains_typeattributeset_members(
                policy,
                "vendor_hal_qspmhal_client",
                ("bootanim", "surfaceflinger", "occe_create"),
            ):
                missing.append(render_attribute_extensions()[0])
            if missing:
                raise PolicyError(
                    "统一 SELinux policy 缺少 AVC 规则：" + missing[0]
                )
            return policy
        for statement in render_statements(api_version):
            if statement in policy.splitlines():
                raise PolicyError(
                    f"目标 CIL 已存在未受补丁管理的 AVC 策略语句：{statement}"
                )
    return _replace_managed_fragment(policy, fragment)


def _context_key(path: str) -> str:
    """Normalize the harmless backslash differences used by file_contexts."""

    return path.replace("\\", "")


def _context_matches_override(path: str, override_path: str) -> bool:
    """Match exact paths while also recognizing the common escaped spelling."""

    normalized = _context_key(path)
    normalized_override = _context_key(override_path)
    if normalized == normalized_override:
        return True
    # The BSG entry is deliberately a character class.  Do not treat the
    # existing dedicated LUN4 rule as an override target.
    if override_path == "/dev/0:0:0:[0-35]":
        return normalized in {f"/dev/0:0:0:{index}" for index in (0, 1, 2, 3, 5)}
    return False


def patch_contexts(
    contexts: str,
    vendor_policy: str = "",
    system_ext_policy: str = "",
    *,
    include_device_nodes: bool = True,
) -> str:
    """Apply the two exact runtime labels and remain idempotent.

    Existing entries for the same normalized path are replaced.  Duplicate
    active entries are rejected because their precedence would depend on the
    file-context compiler rather than this patch.
    """

    if include_device_nodes and not contains_symbol(vendor_policy, "vendor_bsg_device"):
        raise PolicyError("目标 vendor CIL 缺少 vendor_bsg_device")
    if not contains_symbol(system_ext_policy, "qsguard_exec"):
        raise PolicyError("system_ext_sepolicy.cil 缺少 qsguard_exec")

    lines = contexts.splitlines(keepends=True)
    overrides = CONTEXT_OVERRIDES if include_device_nodes else CONTEXT_OVERRIDES[1:]
    override_by_key = {_context_key(path): (path, label) for path, label in overrides}
    occurrences: dict[str, list[int]] = {key: [] for key in override_by_key}
    for index, line in enumerate(lines):
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 2:
            raise PolicyError(f"file_contexts 条目格式无效（第 {index + 1} 行）")
        for key, (override_path, _) in override_by_key.items():
            if _context_matches_override(fields[0], override_path):
                occurrences[key].append(index)

    for key, indexes in occurrences.items():
        if len(indexes) > 1:
            raise PolicyError(f"file_contexts 存在重复覆盖路径：{override_by_key[key][0]}")

    newline = "\n"
    # A context file may express a path as a regular expression.  The exact
    # override key is intentionally normalized only for matching; preserve
    # the selected entry's path spelling when replacing an existing line.
    existing_paths: dict[str, str] = {}
    for index, line in enumerate(lines):
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        for override_key, (override_path, _) in override_by_key.items():
            if _context_matches_override(fields[0], override_path):
                existing_paths[override_key] = fields[0]
    for key, (path, label) in override_by_key.items():
        replacement_path = existing_paths.get(key, path)
        replacement = f"{replacement_path} {label}{newline}"
        if occurrences[key]:
            lines[occurrences[key][0]] = replacement
        else:
            if lines and not lines[-1].endswith(("\n", "\r")):
                lines[-1] += newline
            lines.append(replacement)
    return "".join(lines)


def patch_property_contexts(
    property_contexts: str,
    vendor_policy: str,
    api_version: str,
) -> str:
    """Relabel only the MI-SF/DFPS keys and prefixes proven necessary on the device.

    A single existing entry for each managed key is replaced.  A more specific
    entry under a managed wildcard with another label is rejected because it
    would silently take precedence over this patch.  Broader platform/vendor
    fallback prefixes remain untouched and are safely overridden by the longer
    keys.
    """

    validate_property_context_policy(vendor_policy, api_version)

    lines = property_contexts.splitlines(keepends=True)
    occurrences: dict[str, list[int]] = {
        key: [] for key, _ in PROPERTY_CONTEXT_RULES
    }
    relevant_entries: dict[str, int] = {}
    for index, line in enumerate(lines):
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        fields = stripped.split()
        if len(fields) < 2:
            raise PolicyError(
                f"property_contexts 条目格式无效（第 {index + 1} 行）"
            )
        key, label = fields[:2]
        matching_rules = tuple(
            rule_key
            for rule_key, is_prefix in PROPERTY_CONTEXT_RULES
            if (key.startswith(rule_key) if is_prefix else key == rule_key)
        )
        if not matching_rules:
            continue
        previous_index = relevant_entries.setdefault(key, index)
        if previous_index != index:
            raise PolicyError(f"property_contexts 存在重复属性键：{key}")
        for rule_key in matching_rules:
            if key == rule_key:
                occurrences[rule_key].append(index)
            elif label != PROPERTY_CONTEXT_LABEL:
                raise PolicyError(
                    "property_contexts 存在覆盖受控前缀的更具体冲突条目："
                    f"{key}（前缀 {rule_key}）"
                )

    for rule_key, indexes in occurrences.items():
        if len(indexes) > 1:
            raise PolicyError(f"property_contexts 存在重复受控键：{rule_key}")

    newline = "\n"
    for rule_key, is_prefix in PROPERTY_CONTEXT_RULES:
        match_operation = "prefix" if is_prefix else "exact"
        replacement = (
            f"{rule_key} {PROPERTY_CONTEXT_LABEL} {match_operation}{newline}"
        )
        if occurrences[rule_key]:
            lines[occurrences[rule_key][0]] = replacement
        else:
            if lines and not lines[-1].endswith(("\n", "\r")):
                lines[-1] += newline
            lines.append(replacement)
    return "".join(lines)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--platform-policy", required=True, type=Path)
    parser.add_argument("--versioned-policy", required=True, type=Path)
    parser.add_argument("--system-ext-policy", type=Path)
    parser.add_argument("--contexts", type=Path)
    parser.add_argument("--property-contexts", type=Path)
    parser.add_argument(
        "--qguard-only",
        action="store_true",
        help="只写入 qguard 标签（用于分区打包 metadata，不写运行时设备节点模式）",
    )
    parser.add_argument("--api-version", required=True)
    output_group = parser.add_mutually_exclusive_group()
    output_group.add_argument("--output", type=Path)
    output_group.add_argument(
        "--fragment-output",
        type=Path,
        help="只输出本补丁的 CIL 规则片段，不直接修改目标 policy",
    )
    output_group.add_argument("--check", action="store_true")
    parser.add_argument("--contexts-output", type=Path)
    parser.add_argument("--property-contexts-output", type=Path)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    if not re.fullmatch(r"[0-9]+", args.api_version):
        print("! AVC policy API 版本格式无效", file=sys.stderr)
        return 1
    if args.contexts_output is not None and args.contexts is None:
        print("! 指定 contexts-output 时必须同时指定 contexts", file=sys.stderr)
        return 1
    if args.property_contexts_output is not None and args.property_contexts is None:
        print(
            "! 指定 property-contexts-output 时必须同时指定 property-contexts",
            file=sys.stderr,
        )
        return 1
    if args.check and (
        args.contexts_output is not None
        or args.property_contexts_output is not None
    ):
        print("! check 不能同时指定 contexts 输出", file=sys.stderr)
        return 1
    if args.fragment_output is not None and (
        args.contexts is not None
        or args.property_contexts is not None
        or args.contexts_output is not None
        or args.property_contexts_output is not None
    ):
        print("! fragment-output 不能同时处理 contexts", file=sys.stderr)
        return 1
    try:
        policy = args.policy.read_text(encoding="utf-8")
        platform_policy = args.platform_policy.read_text(encoding="utf-8")
        versioned_policy = args.versioned_policy.read_text(encoding="utf-8")
        system_ext_policy = (
            args.system_ext_policy.read_text(encoding="utf-8")
            if args.system_ext_policy is not None
            else ""
        )
        if args.fragment_output is not None:
            validate_symbols(
                policy,
                platform_policy,
                versioned_policy,
                args.api_version,
                system_ext_policy,
            )
            if args.fragment_output.is_symlink():
                raise PolicyError("fragment-output 不能是符号链接")
            args.fragment_output.write_text(
                build_fragment_body(args.api_version),
                encoding="utf-8",
                newline="\n",
            )
            return 0

        patched = patch_policy(
            policy,
            platform_policy,
            versioned_policy,
            args.api_version,
            system_ext_policy,
        )
        patched_contexts = None
        original_contexts = None
        if args.contexts is not None:
            original_contexts = args.contexts.read_text(encoding="utf-8")
            patched_contexts = patch_contexts(
                original_contexts,
                policy,
                system_ext_policy,
                include_device_nodes=not args.qguard_only,
            )
        patched_property_contexts = None
        original_property_contexts = None
        if args.property_contexts is not None:
            original_property_contexts = args.property_contexts.read_text(
                encoding="utf-8"
            )
            patched_property_contexts = patch_property_contexts(
                original_property_contexts,
                policy,
                args.api_version,
            )
        if args.check:
            if patched != policy:
                raise PolicyError("目标 CIL 尚未完整应用 AVC 规则片段")
            if original_contexts is not None and patched_contexts != original_contexts:
                raise PolicyError("目标 file_contexts 尚未完整应用 AVC 标签")
            if (
                original_property_contexts is not None
                and patched_property_contexts != original_property_contexts
            ):
                raise PolicyError(
                    "目标 property_contexts 尚未完整应用 MI-SF 属性标签"
                )
        else:
            if args.output is not None:
                args.output.write_text(patched, encoding="utf-8", newline="\n")
            if args.contexts_output is not None:
                if patched_contexts is None:
                    raise PolicyError("指定 contexts-output 时必须同时指定 contexts")
                args.contexts_output.write_text(
                    patched_contexts, encoding="utf-8", newline="\n"
                )
            if args.property_contexts_output is not None:
                if patched_property_contexts is None:
                    raise PolicyError(
                        "指定 property-contexts-output 时必须同时指定 property-contexts"
                    )
                args.property_contexts_output.write_text(
                    patched_property_contexts, encoding="utf-8", newline="\n"
                )
            if (
                args.output is None
                and args.contexts_output is None
                and args.property_contexts_output is None
            ):
                raise PolicyError(
                    "必须指定 output、contexts-output、property-contexts-output 或 check"
                )
    except (OSError, UnicodeError, PolicyError) as error:
        print(f"! vendor AVC policy：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
