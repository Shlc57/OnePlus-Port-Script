#!/usr/bin/env python3
"""Generic, source-aware SELinux merge interface for a final vendor tree.

The final vendor tree is authoritative.  When generated ``base_typeattr``
expressions are identical, CIL can be merged conservatively.  When they differ,
the source CIL is not safe to transplant; the interface instead imports only
context entries whose SELinux type already exists in the final vendor policy.

This module deliberately contains no device AVC rules.  A caller-specific
patch (currently ``common/fix_vendor_avc``) owns those rules and invokes this
interface as one stage of its transaction.
"""

from __future__ import annotations

import argparse
import re
import sys
from dataclasses import dataclass
from pathlib import Path


CONTEXT_FILES = (
    "vendor_file_contexts",
    "vendor_hwservice_contexts",
    "vendor_keystore2_key_contexts",
    "vendor_property_contexts",
    "vendor_seapp_contexts",
    "vendor_service_contexts",
    "vendor_tee_service_contexts",
    "vndservice_contexts",
)
VERSION_FILES = (
    "plat_sepolicy_vers.txt",
    "genfs_labels_version.txt",
)
BASE_TYPEATTR_RE = re.compile(r"^base_typeattr_[0-9]+(?:_[A-Za-z0-9]+)?$")
NAMED_CIL_HEADS = {
    "boolean",
    "category",
    "class",
    "common",
    "role",
    "sensitivity",
    "sid",
    "tunable",
    "type",
    "typeattribute",
    "typealias",
    "userattribute",
    "user",
}


class MergeError(ValueError):
    """Raised when two policies cannot safely be combined."""


# Every policy fragment (including compatible source-vendor imports) is owned
# by this interface once it has been written.  Individual patches only provide
# statements; they never choose a destination marker or append to CIL directly.
POLICY_BEGIN_MARKER = ";; BEGIN common/selinux_merge managed policy"
POLICY_END_MARKER = ";; END common/selinux_merge managed policy"
# Keep the old names as in-module aliases for callers which only use the
# generic merge function.  They intentionally point at the new single block.
CIL_BEGIN_MARKER = POLICY_BEGIN_MARKER
CIL_END_MARKER = POLICY_END_MARKER
CONTEXT_BEGIN_MARKER = "# BEGIN common/selinux_merge imported mi_vendor entries"
CONTEXT_END_MARKER = "# END common/selinux_merge imported mi_vendor entries"
# The first implementation was exposed as a standalone patch.  Keep its
# managed block spelling recognizable while the unified caller migrates the
# already-generated tree in place; no old command/API is retained.
LEGACY_CIL_BEGIN_MARKER = ";; BEGIN common/merge_vendor_sepolicy imported mi_vendor rules"
LEGACY_CIL_END_MARKER = ";; END common/merge_vendor_sepolicy imported mi_vendor rules"
LEGACY_CONTEXT_BEGIN_MARKER = "# BEGIN common/merge_vendor_sepolicy imported mi_vendor entries"
LEGACY_CONTEXT_END_MARKER = "# END common/merge_vendor_sepolicy imported mi_vendor entries"
LEGACY_AVC_BEGIN_MARKER = ";; BEGIN common/fix_vendor_avc evidence-backed rules"
LEGACY_AVC_END_MARKER = ";; END common/fix_vendor_avc evidence-backed rules"
LEGACY_IMPORTED_CIL_BEGIN_MARKER = ";; BEGIN common/selinux_merge imported mi_vendor rules"
LEGACY_IMPORTED_CIL_END_MARKER = ";; END common/selinux_merge imported mi_vendor rules"

MANAGED_POLICY_MARKERS = (
    (POLICY_BEGIN_MARKER, POLICY_END_MARKER),
    (LEGACY_AVC_BEGIN_MARKER, LEGACY_AVC_END_MARKER),
    (LEGACY_CIL_BEGIN_MARKER, LEGACY_CIL_END_MARKER),
    (LEGACY_IMPORTED_CIL_BEGIN_MARKER, LEGACY_IMPORTED_CIL_END_MARKER),
)
SOURCE_POLICY_MARKERS = (
    (POLICY_BEGIN_MARKER, POLICY_END_MARKER),
    (LEGACY_CIL_BEGIN_MARKER, LEGACY_CIL_END_MARKER),
    (LEGACY_IMPORTED_CIL_BEGIN_MARKER, LEGACY_IMPORTED_CIL_END_MARKER),
)
CONTEXT_MARKERS = (
    (CONTEXT_BEGIN_MARKER, CONTEXT_END_MARKER),
    (LEGACY_CONTEXT_BEGIN_MARKER, LEGACY_CONTEXT_END_MARKER),
)
TEMPLATE_RE = re.compile(r"\$\{([A-Za-z_][A-Za-z0-9_]*)\}")


@dataclass(frozen=True)
class Statement:
    raw: str
    start: int
    end: int


def normalize_cil(value: str) -> str:
    return " ".join(value.split())


def migrate_managed_markers(
    text: str,
    *,
    begin_marker: str,
    end_marker: str,
    legacy_begin_marker: str,
    legacy_end_marker: str,
) -> str:
    """Normalize the one managed import block without touching other comments."""

    lines = text.splitlines(keepends=True)
    current_begin = [
        index
        for index, line in enumerate(lines)
        if line.rstrip("\r\n") == begin_marker
    ]
    current_end = [
        index
        for index, line in enumerate(lines)
        if line.rstrip("\r\n") == end_marker
    ]
    legacy_begin = [
        index
        for index, line in enumerate(lines)
        if line.rstrip("\r\n") == legacy_begin_marker
    ]
    legacy_end = [
        index
        for index, line in enumerate(lines)
        if line.rstrip("\r\n") == legacy_end_marker
    ]
    if len(current_begin) > 1 or len(current_end) > 1:
        raise MergeError("SELinux 合并接口的当前边界标记重复")
    if len(legacy_begin) > 1 or len(legacy_end) > 1:
        raise MergeError("SELinux 合并接口的旧边界标记重复")
    if current_begin or current_end:
        if len(current_begin) != 1 or len(current_end) != 1:
            raise MergeError("SELinux 合并接口的当前边界标记不完整")
        if current_end[0] < current_begin[0]:
            raise MergeError("SELinux 合并接口的当前边界标记顺序错误")
    if legacy_begin or legacy_end:
        if len(legacy_begin) != 1 or len(legacy_end) != 1:
            raise MergeError("SELinux 合并接口的旧边界标记不完整")
        if legacy_end[0] < legacy_begin[0]:
            raise MergeError("SELinux 合并接口的旧边界标记顺序错误")
    if current_begin and legacy_begin:
        raise MergeError("SELinux 合并接口同时存在新旧边界标记")
    if legacy_begin:
        for index in legacy_begin:
            line_ending = "\n" if lines[index].endswith("\n") else ""
            lines[index] = begin_marker + line_ending
        for index in legacy_end:
            line_ending = "\n" if lines[index].endswith("\n") else ""
            lines[index] = end_marker + line_ending
    return "".join(lines)


def extract_managed_blocks(
    text: str,
    marker_pairs: tuple[tuple[str, str], ...] = MANAGED_POLICY_MARKERS,
) -> tuple[str, list[str]]:
    """Remove known managed blocks and return their bodies in file order.

    Older revisions wrote AVC rules and source-vendor imports under separate
    markers.  The unified interface must consume those blocks before adding a
    new one, otherwise rerunning a patch would leave duplicate policy.  Marker
    lines are comments, so extracting them does not alter unmanaged CIL.
    """

    lines = text.splitlines(keepends=True)
    spans: list[tuple[int, int, str]] = []
    for begin_marker, end_marker in marker_pairs:
        begin_indexes = [
            index
            for index, line in enumerate(lines)
            if line.rstrip("\r\n") == begin_marker
        ]
        end_indexes = [
            index
            for index, line in enumerate(lines)
            if line.rstrip("\r\n") == end_marker
        ]
        if len(begin_indexes) > 1 or len(end_indexes) > 1:
            raise MergeError(f"SELinux 托管策略边界标记重复：{begin_marker}")
        if bool(begin_indexes) != bool(end_indexes):
            raise MergeError(f"SELinux 托管策略边界标记不完整：{begin_marker}")
        if not begin_indexes:
            continue
        begin_index = begin_indexes[0]
        end_index = end_indexes[0]
        if end_index < begin_index:
            raise MergeError(f"SELinux 托管策略边界标记顺序错误：{begin_marker}")
        spans.append((begin_index, end_index, begin_marker))

    spans.sort()
    for previous, current in zip(spans, spans[1:]):
        if current[0] <= previous[1]:
            raise MergeError("SELinux 托管策略边界标记互相重叠")

    bodies = ["".join(lines[begin + 1 : end]) for begin, end, _ in spans]
    if not spans:
        return text, bodies
    covered = {index for begin, end, _ in spans for index in range(begin, end + 1)}
    cleaned = "".join(line for index, line in enumerate(lines) if index not in covered)
    return cleaned, bodies


def expand_fragment_template(fragment: str, api_version: str) -> str:
    """Expand the deliberately tiny fragment template language.

    Only ``${API_VERSION}`` is defined.  Rejecting every other placeholder is
    important: silently leaving a typo in a CIL fragment produces a policy
    which may compile differently on another API level.
    """

    if not re.fullmatch(r"[0-9]+", api_version):
        raise MergeError(f"API 版本无效：{api_version}")

    def replace(match: re.Match[str]) -> str:
        if match.group(1) != "API_VERSION":
            raise MergeError(f"SELinux 片段包含未支持的变量：{match.group(1)}")
        return api_version

    expanded = TEMPLATE_RE.sub(replace, fragment)
    if "${" in expanded:
        raise MergeError("SELinux 片段包含未解析的变量")
    return expanded


def split_cil_statements(policy: str) -> list[Statement]:
    """Return top-level CIL S-expressions without discarding target comments."""
    statements: list[Statement] = []
    start: int | None = None
    depth = 0
    quoted = False
    escaped = False
    comment = False

    for index, character in enumerate(policy):
        if comment:
            if character == "\n":
                comment = False
            continue
        if quoted:
            if escaped:
                escaped = False
            elif character == "\\":
                escaped = True
            elif character == '"':
                quoted = False
            continue
        if character == ";":
            comment = True
            continue
        if character == '"':
            quoted = True
            continue
        if character == "(":
            if depth == 0:
                start = index
            depth += 1
            continue
        if character == ")":
            depth -= 1
            if depth < 0:
                raise MergeError("CIL 存在未匹配的右括号")
            if depth == 0:
                assert start is not None
                statements.append(Statement(policy[start : index + 1], start, index + 1))
                start = None

    if quoted:
        raise MergeError("CIL 存在未闭合的字符串")
    if depth != 0 or start is not None:
        raise MergeError("CIL 存在未闭合的表达式")
    return statements


def tokenize_cil(statement: str) -> list[str]:
    tokens: list[str] = []
    index = 0
    while index < len(statement):
        character = statement[index]
        if character.isspace():
            index += 1
            continue
        if character in "()":
            tokens.append(character)
            index += 1
            continue
        if character == '"':
            start = index
            index += 1
            escaped = False
            while index < len(statement):
                current = statement[index]
                if escaped:
                    escaped = False
                elif current == "\\":
                    escaped = True
                elif current == '"':
                    index += 1
                    break
                index += 1
            else:
                raise MergeError("CIL 字符串未闭合")
            tokens.append(statement[start:index])
            continue
        start = index
        while index < len(statement) and not statement[index].isspace() and statement[index] not in "()":
            index += 1
        tokens.append(statement[start:index])
    return tokens


def cil_head(statement: Statement) -> str:
    tokens = tokenize_cil(statement.raw)
    if len(tokens) < 2 or tokens[0] != "(":
        raise MergeError("CIL 顶层表达式格式无效")
    return tokens[1]


def cil_key(statement: Statement) -> tuple[str, ...] | None:
    tokens = tokenize_cil(statement.raw)
    head = cil_head(statement)
    if head == "genfscon":
        if len(tokens) < 4:
            raise MergeError("genfscon 表达式缺少文件系统或路径")
        return head, tokens[2], tokens[3]
    if head == "typeattributeset":
        if len(tokens) < 4:
            raise MergeError("typeattributeset 表达式缺少属性名")
        return head, tokens[2]
    if head in NAMED_CIL_HEADS:
        if len(tokens) < 4:
            raise MergeError(f"{head} 表达式缺少名称")
        return head, tokens[2]
    return None


def simple_typeattributeset(statement: Statement) -> tuple[str, list[str]] | None:
    tokens = tokenize_cil(statement.raw)
    if len(tokens) < 6 or tokens[:4] != ["(", "typeattributeset", tokens[2], "("]:
        return None
    if tokens[-2:] != [")", ")"] or any(token in {"(", ")"} for token in tokens[4:-2]):
        return None
    return tokens[2], tokens[4:-2]


def make_typeattributeset(attribute: str, members: list[str]) -> str:
    return f"(typeattributeset {attribute} ({' '.join(members)}))"


def build_key_map(
    statements: list[Statement],
    policy_label: str = "目标 CIL",
) -> dict[tuple[str, ...], Statement]:
    result: dict[tuple[str, ...], Statement] = {}
    for statement in statements:
        key = cil_key(statement)
        if key is None:
            continue
        if key in result and normalize_cil(result[key].raw) != normalize_cil(statement.raw):
            raise MergeError(
                f"{policy_label} 内部存在冲突的策略键：{' '.join(key)}"
            )
        result[key] = statement
    return result


def validate_base_typeattrs(target: list[Statement], source: list[Statement]) -> None:
    def collect(statements: list[Statement]) -> dict[str, str]:
        result: dict[str, str] = {}
        for statement in statements:
            key = cil_key(statement)
            if key is None or key[0] != "typeattributeset" or not BASE_TYPEATTR_RE.fullmatch(key[1]):
                continue
            value = normalize_cil(statement.raw)
            previous = result.setdefault(key[1], value)
            if previous != value:
                raise MergeError(f"同一策略中 base_typeattr 定义重复：{key[1]}")
        return result

    target_attrs = collect(target)
    source_attrs = collect(source)
    if target_attrs != source_attrs:
        missing_from_target = sorted(source_attrs.keys() - target_attrs.keys())
        missing_from_source = sorted(target_attrs.keys() - source_attrs.keys())
        different = sorted(
            name
            for name in target_attrs.keys() & source_attrs.keys()
            if target_attrs[name] != source_attrs[name]
        )
        details: list[str] = []
        if missing_from_target:
            details.append(f"底包缺少 {len(missing_from_target)} 项")
        if missing_from_source:
            details.append(f"原包缺少 {len(missing_from_source)} 项")
        if different:
            details.append(f"{len(different)} 项定义不同（例如 {different[0]}）")
        raise MergeError("base_typeattr ABI 不兼容：" + "；".join(details))


def _merge_cil_statements(
    target_policy: str,
    source_policy: str,
    *,
    validate_abi: bool,
    source_label: str,
) -> tuple[str, list[str], int, int]:
    """Merge one statement stream without creating a marker block.

    Keeping marker creation outside this primitive lets ``merge-policy`` feed
    several patch-owned fragments through the same conflict rules and emit one
    deterministic managed block at the end.
    """

    target = split_cil_statements(target_policy)
    source = split_cil_statements(source_policy)
    if validate_abi:
        validate_base_typeattrs(target, source)

    target_by_key = build_key_map(target)
    # A single source vendor policy must not contain ambiguous declarations.
    # Fragment streams are passed one at a time, so this also allows two
    # independent patches to extend the same simple typeattributeset safely.
    build_key_map(source, source_label)
    target_normalized = {normalize_cil(statement.raw) for statement in target}
    replacements: dict[tuple[int, int], str] = {}
    additions: list[str] = []
    added = 0
    target_priority_conflicts = 0
    merged_attribute_sets = 0

    for source_statement in source:
        source_normalized = normalize_cil(source_statement.raw)
        if source_normalized in target_normalized:
            continue
        key = cil_key(source_statement)
        if key is None:
            additions.append(source_statement.raw.strip())
            target_normalized.add(source_normalized)
            added += 1
            continue
        target_statement = target_by_key.get(key)
        if target_statement is None:
            additions.append(source_statement.raw.strip())
            target_normalized.add(source_normalized)
            target_by_key[key] = source_statement
            added += 1
            continue
        if key[0] == "genfscon":
            # The final vendor policy owns path labels.  A source entry with
            # the same key is intentionally ignored, even if its value differs.
            target_priority_conflicts += 1
            continue
        if key[0] == "typeattributeset":
            attribute = key[1]
            if BASE_TYPEATTR_RE.fullmatch(attribute):
                raise MergeError(f"base_typeattr 通过 ABI 校验后仍未能去重：{attribute}")
            target_simple = simple_typeattributeset(target_statement)
            source_simple = simple_typeattributeset(source_statement)
            if target_simple is None or source_simple is None:
                raise MergeError(f"无法安全合并复杂 typeattributeset：{attribute}")
            members = list(target_simple[1])
            for member in source_simple[1]:
                if member not in members:
                    members.append(member)
            replacement = make_typeattributeset(attribute, members)
            replacements[(target_statement.start, target_statement.end)] = replacement
            target_normalized.add(normalize_cil(replacement))
            merged_attribute_sets += 1
            continue
        raise MergeError(f"同名 CIL 声明内容冲突：{' '.join(key)}")

    merged = target_policy
    for (start, end), replacement in sorted(replacements.items(), reverse=True):
        merged = merged[:start] + replacement + merged[end:]
    validate_genfscon_uniqueness(merged)
    return merged, additions, target_priority_conflicts, merged_attribute_sets


def _append_managed_block(
    policy: str,
    statements: list[str],
    marker_pairs: tuple[tuple[str, str], ...] = MANAGED_POLICY_MARKERS,
) -> str:
    """Append statements while retaining any current managed block content."""

    policy, existing_bodies = extract_managed_blocks(policy, marker_pairs)
    combined: list[str] = []
    seen: set[str] = set()
    for body in existing_bodies:
        for statement in split_cil_statements(body):
            normalized = normalize_cil(statement.raw)
            if normalized not in seen:
                combined.append(statement.raw.strip())
                seen.add(normalized)
    for statement in statements:
        normalized = normalize_cil(statement)
        if normalized not in seen:
            combined.append(statement.strip())
            seen.add(normalized)
    if not combined:
        return policy
    policy = policy.rstrip("\n")
    return (
        f"{policy}\n\n{POLICY_BEGIN_MARKER}\n"
        + "\n".join(combined)
        + f"\n{POLICY_END_MARKER}\n"
    )


def merge_cil(target_policy: str, source_policy: str) -> tuple[str, int, int, int]:
    """Merge a compatible source vendor CIL and emit the unified marker block."""

    # Source imports may be rerun after an older standalone patch.  Consume
    # every known managed policy block before merging the fresh source stream.
    target_policy, old_bodies = extract_managed_blocks(
        target_policy, SOURCE_POLICY_MARKERS
    )
    preserved_additions: list[str] = []
    for body in old_bodies:
        target_policy, body_additions, _, _ = _merge_cil_statements(
            target_policy,
            body,
            validate_abi=False,
            source_label="已生成托管 CIL",
        )
        preserved_additions.extend(body_additions)
    if preserved_additions:
        target_policy = _append_managed_block(
            target_policy,
            preserved_additions,
            SOURCE_POLICY_MARKERS,
        )
    merged, additions, conflicts, attributes = _merge_cil_statements(
        target_policy,
        source_policy,
        validate_abi=True,
        source_label="原包 CIL",
    )
    newly_added = len(additions)
    if additions:
        merged = _append_managed_block(merged, additions, SOURCE_POLICY_MARKERS)
    merged, managed_bodies = extract_managed_blocks(merged, SOURCE_POLICY_MARKERS)
    additions = [line for body in managed_bodies for line in split_cil_statements(body)]
    # ``managed_bodies`` contains raw CIL expressions, not strings.  Normalize
    # them only at the final append so reruns retain deterministic formatting.
    additions = [statement.raw.strip() for statement in additions]
    if additions:
        merged = _append_managed_block(merged, additions, SOURCE_POLICY_MARKERS)
    return merged, newly_added, conflicts, attributes


def merge_policy_fragments(
    policy: str,
    fragments: list[str],
    api_version: str,
    replace_markers: tuple[tuple[str, str], ...] = (),
) -> tuple[str, int, int, int]:
    """Merge patch-owned CIL fragments through one managed policy block.

    ``fragments`` are intentionally opaque to this module: no AVC, display or
    vendor-specific rule is embedded here.  Existing blocks from both the old
    standalone patches and this interface are migrated and deduplicated.
    """

    # A provider can explicitly supersede a legacy block when its rule
    # generator has changed (for example the AVC patch's unsafe early
    # revision).  Marker names are metadata, not policy rules; the generic
    # interface still remains unaware of the statements themselves.
    for marker_pair in replace_markers:
        policy, _ = extract_managed_blocks(policy, (marker_pair,))
    target, old_bodies = extract_managed_blocks(policy)
    candidate_bodies: list[str] = list(old_bodies)
    for fragment in fragments:
        expanded = expand_fragment_template(fragment, api_version)
        fragment_without_markers, fragment_bodies = extract_managed_blocks(expanded)
        candidate_bodies.extend(fragment_bodies)
        # A normal fragment has no marker; a mixed fragment may contain both
        # comments/markers and additional unmarked expressions, so retain the
        # residual stream as well.
        if fragment_without_markers.strip():
            candidate_bodies.append(fragment_without_markers)

    added = 0
    legacy_added = 0
    conflicts = 0
    attributes = 0
    for index, body in enumerate(candidate_bodies):
        target, body_additions, body_conflicts, body_attributes = _merge_cil_statements(
            target,
            body,
            validate_abi=False,
            source_label=f"SELinux 片段 {index + 1}",
        )
        if body_additions:
            # Keep additions visible to the next fragment so exact statements
            # and typeattributeset members are deduplicated across providers.
            target = _append_managed_block(target, body_additions)
            if index < len(old_bodies):
                legacy_added += len(body_additions)
        added += len(body_additions)
        conflicts += body_conflicts
        attributes += body_attributes

    target, managed_bodies = extract_managed_blocks(target)
    additions = [
        statement.raw.strip()
        for body in managed_bodies
        for statement in split_cil_statements(body)
    ]
    if additions:
        target = _append_managed_block(target, additions)
    return target, max(0, added - legacy_added), conflicts, attributes


def validate_genfscon_uniqueness(policy: str) -> None:
    seen: dict[tuple[str, ...], str] = {}
    for statement in split_cil_statements(policy):
        key = cil_key(statement)
        if key is None or key[0] != "genfscon":
            continue
        normalized = normalize_cil(statement.raw)
        previous = seen.setdefault(key, normalized)
        if previous != normalized:
            raise MergeError(f"合并结果存在冲突的 genfscon：{' '.join(key)}")


def context_key(filename: str, line: str) -> str:
    fields = line.split()
    if filename == "vendor_seapp_contexts":
        # domain/type/level* are outputs; the remaining fields select the app.
        # Treat two entries with the same selectors as one key so the bottom
        # package keeps priority instead of importing a competing assignment.
        output_fields = {"domain", "type", "level", "levelFrom"}
        selectors: list[str] = []
        for field in fields:
            if "=" not in field:
                raise MergeError(
                    f"{filename} 存在格式无效的 context 条目：{line}"
                )
            name, _ = field.split("=", 1)
            if name not in output_fields:
                selectors.append(field.replace("\\", ""))
        if not selectors:
            raise MergeError(f"{filename} 条目缺少应用选择器：{line}")
        return " ".join(selectors)
    if len(fields) < 2:
        raise MergeError(f"{filename} 存在格式无效的 context 条目：{line}")
    # Context compilers accept both escaped and unescaped punctuation.  Treat
    # those spellings as one path for conflict/deduplication, while retaining
    # the original selected line when writing it back.
    return fields[0].replace("\\", "")


def context_policy_types(line: str) -> set[str]:
    return set(
        re.findall(
            r"(?:u:object_r:|(?:domain|type)=)([A-Za-z0-9_]+)(?::s0)?",
            line,
        )
    )


def policy_types(policy: str) -> set[str]:
    return {
        key[1]
        for statement in split_cil_statements(policy)
        if (key := cil_key(statement)) is not None and key[0] == "type"
    }


def merge_contexts(
    target: str,
    source: str,
    filename: str,
    allowed_types: set[str] | None = None,
) -> tuple[str, int, int, int]:
    target, managed_bodies = extract_managed_blocks(target, CONTEXT_MARKERS)
    target_lines = target.splitlines()
    seen: dict[str, str] = {}
    managed_entries: list[str] = []
    for raw in target_lines:
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key = context_key(filename, stripped)
        normalized = " ".join(stripped.split())
        previous = seen.setdefault(key, normalized)
        if previous != normalized:
            raise MergeError(f"目标 {filename} 存在冲突条目：{key}")
    for body in managed_bodies:
        for raw in body.splitlines():
            stripped = raw.strip()
            if not stripped or stripped.startswith("#"):
                managed_entries.append(raw)
                continue
            key = context_key(filename, stripped)
            normalized = " ".join(stripped.split())
            previous = seen.setdefault(key, normalized)
            if previous != normalized:
                raise MergeError(f"目标 {filename} 存在冲突条目：{key}")
            managed_entries.append(stripped)

    additions: list[str] = []
    added = 0
    conflicts = 0
    unavailable_types = 0
    for raw in source.splitlines():
        stripped = raw.strip()
        if not stripped or stripped.startswith("#"):
            continue
        key = context_key(filename, stripped)
        normalized = " ".join(stripped.split())
        entry_types = context_policy_types(normalized)
        if allowed_types is not None and not entry_types.issubset(allowed_types):
            unavailable_types += 1
            continue
        previous = seen.get(key)
        if previous is None:
            # Keep the source spelling (including escaped punctuation) for a
            # newly selected entry; only the comparison key is normalized.
            additions.append(stripped)
            seen[key] = normalized
            added += 1
        elif previous != normalized:
            conflicts += 1

    merged_entries: list[str] = []
    seen_entries: set[str] = set()
    for entry in [*managed_entries, *additions]:
        if not entry.strip() or entry.lstrip().startswith("#"):
            merged_entries.append(entry)
            continue
        entry_key = " ".join(entry.split())
        if entry_key not in seen_entries:
            merged_entries.append(entry)
            seen_entries.add(entry_key)
    merged = target
    if merged_entries:
        merged = merged.rstrip("\n")
        merged += (
            f"\n\n{CONTEXT_BEGIN_MARKER}\n"
            + "\n".join(merged_entries)
            + f"\n{CONTEXT_END_MARKER}\n"
        )
    return merged, added, conflicts, unavailable_types


def ensure_regular_file(path: Path, label: str) -> None:
    if not path.is_file() or path.is_symlink():
        raise MergeError(f"{label} 不存在或不是普通文件：{path}")


def read_version_marker(path: Path, label: str) -> str:
    ensure_regular_file(path, label)
    value = path.read_text(encoding="utf-8").strip()
    if not value or "\n" in value or "\r" in value:
        raise MergeError(f"{label} 不是单一有效版本标记：{path}")
    return value


def write_output_file(path: Path, content: str, label: str) -> None:
    if path.exists() or path.is_symlink():
        if path.is_symlink() or not path.is_file():
            raise MergeError(f"{label} 不是可安全覆盖的普通文件：{path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content, encoding="utf-8", newline="\n")


def merge_directories(target_dir: Path, source_dir: Path, output_dir: Path) -> None:
    if not target_dir.is_dir() or target_dir.is_symlink():
        raise MergeError(f"底包 SELinux 目录无效：{target_dir}")
    if not source_dir.is_dir() or source_dir.is_symlink():
        raise MergeError(f"原包 SELinux 目录无效：{source_dir}")
    if output_dir.exists():
        if not output_dir.is_dir() or output_dir.is_symlink():
            raise MergeError(f"输出目录无效：{output_dir}")
    else:
        output_dir.mkdir(parents=True)

    target_policy = target_dir / "vendor_sepolicy.cil"
    source_policy = source_dir / "vendor_sepolicy.cil"
    ensure_regular_file(target_policy, "底包 vendor policy")
    ensure_regular_file(source_policy, "原包 vendor policy")
    for version_filename in VERSION_FILES:
        target_version = read_version_marker(
            target_dir / version_filename,
            f"底包 {version_filename}",
        )
        source_version = read_version_marker(
            source_dir / version_filename,
            f"原包 {version_filename}",
        )
        if target_version != source_version:
            raise MergeError(
                f"SELinux 版本标记不一致，拒绝跨 ABI 合并：{version_filename} "
                f"（底包 {target_version}，原包 {source_version}）"
            )
    target_policy_text = target_policy.read_text(encoding="utf-8")
    source_policy_text = source_policy.read_text(encoding="utf-8")
    target_types = policy_types(target_policy_text)
    cil_compatible = True
    try:
        validate_base_typeattrs(
            split_cil_statements(target_policy_text),
            split_cil_statements(source_policy_text),
        )
    except MergeError as error:
        cil_compatible = False
        print(f"WARN vendor_sepolicy.cil: {error}；保留底包 CIL，仅合并现有类型可承载的 contexts")

    if cil_compatible:
        merged_policy, added, cil_conflicts, attributes = merge_cil(
            target_policy_text,
            source_policy_text,
        )
        write_output_file(
            output_dir / target_policy.name,
            merged_policy,
            "vendor SELinux 合并输出",
        )
        print(
            "vendor_sepolicy.cil: "
            f"新增 {added} 条，底包优先跳过 {cil_conflicts} 条 genfscon 冲突，"
            f"合并 {attributes} 个 typeattributeset"
        )

    for filename in CONTEXT_FILES:
        target = target_dir / filename
        source = source_dir / filename
        if not target.exists() or not source.exists():
            print(f"{filename}: 缺少一侧文件，跳过")
            continue
        ensure_regular_file(target, f"底包 {filename}")
        ensure_regular_file(source, f"原包 {filename}")
        merged, context_added, conflicts, unavailable_types = merge_contexts(
            target.read_text(encoding="utf-8"),
            source.read_text(encoding="utf-8"),
            filename,
            None if cil_compatible else target_types,
        )
        write_output_file(
            output_dir / filename,
            merged,
            "vendor SELinux contexts 合并输出",
        )
        print(
            f"{filename}: 新增 {context_added} 条，底包优先跳过 {conflicts} 条冲突，"
            f"跳过 {unavailable_types} 条目标 policy 不含类型的来源条目"
        )


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    vendor_parser = subparsers.add_parser(
        "merge-vendor",
        help="按版本与 CIL ABI 约束合并原包 vendor SELinux 文件",
    )
    vendor_parser.add_argument("--target-dir", required=True, type=Path)
    vendor_parser.add_argument("--source-dir", required=True, type=Path)
    vendor_parser.add_argument("--output-dir", required=True, type=Path)

    policy_parser = subparsers.add_parser(
        "merge-policy",
        help="把一个或多个补丁片段合并到最终 vendor CIL",
    )
    policy_parser.add_argument("--policy", required=True, type=Path)
    policy_parser.add_argument("--output", required=True, type=Path)
    policy_parser.add_argument("--api-version", required=True)
    policy_parser.add_argument(
        "--fragment",
        action="append",
        type=Path,
        default=[],
        help="CIL 片段文件，可重复指定；片段内容由调用方补丁提供",
    )
    policy_parser.add_argument(
        "--replace-marker",
        action="append",
        default=[],
        help="替换旧托管块的 provider 名称（需同时存在对应 END marker）",
    )
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        if args.command == "merge-vendor":
            merge_directories(args.target_dir, args.source_dir, args.output_dir)
        elif args.command == "merge-policy":
            ensure_regular_file(args.policy, "目标 vendor policy")
            fragments: list[str] = []
            for fragment_path in args.fragment:
                ensure_regular_file(fragment_path, "SELinux 片段")
                fragments.append(fragment_path.read_text(encoding="utf-8"))
            replace_markers: list[tuple[str, str]] = []
            for marker_name in args.replace_marker:
                if marker_name == "common/fix_vendor_avc":
                    replace_markers.append(
                        (LEGACY_AVC_BEGIN_MARKER, LEGACY_AVC_END_MARKER)
                    )
                elif marker_name == "common/merge_vendor_sepolicy":
                    replace_markers.append(
                        (LEGACY_CIL_BEGIN_MARKER, LEGACY_CIL_END_MARKER)
                    )
                else:
                    raise MergeError(f"不支持替换的 SELinux marker：{marker_name}")
            merged, added, conflicts, attributes = merge_policy_fragments(
                args.policy.read_text(encoding="utf-8"),
                fragments,
                args.api_version,
                tuple(replace_markers),
            )
            write_output_file(args.output, merged, "SELinux policy 输出")
            print(
                f"vendor policy: 新增 {added} 条，底包优先跳过 {conflicts} 条 genfscon 冲突，"
                f"合并 {attributes} 个 typeattributeset"
            )
        else:  # pragma: no cover - argparse enforces the choices
            raise MergeError(f"未知 SELinux 合并命令：{args.command}")
    except (OSError, UnicodeError, MergeError) as error:
        print(f"! vendor SELinux 合并：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
