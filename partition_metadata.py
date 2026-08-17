#!/usr/bin/env python3
"""Merge and translate Android partition contexts/fsconfig metadata."""

from __future__ import annotations

import argparse
import os
import stat
import sys
import tempfile
from collections import OrderedDict
from pathlib import Path, PurePosixPath
from typing import Iterable, Literal


MetadataKind = Literal["contexts", "fsconfig"]


class MetadataError(RuntimeError):
    pass


def read_lines(path: Path) -> list[str]:
    if path.is_symlink() or not path.is_file():
        raise MetadataError(f"元数据文件不存在或不是普通文件：{path}")
    with path.open("r", encoding="utf-8", errors="surrogateescape", newline=None) as stream:
        return [line.rstrip("\r\n") for line in stream]


def normalize_lines_for_write(
    path: Path, lines: Iterable[str], kind: MetadataKind
) -> list[str]:
    normalized_lines: list[str] = []
    for line_number, line in enumerate(lines, start=1):
        if kind != "contexts" or is_ignored_line(line):
            normalized_lines.append(line)
            continue
        fields = line.split()
        if len(fields) < 2:
            raise MetadataError(f"contexts 条目缺少上下文字段：{path}:{line_number}")
        normalized_lines.append(" ".join(fields))
    return normalized_lines


def write_lines(
    path: Path,
    lines: Iterable[str],
    kind: MetadataKind,
    *,
    preserve_from: Path | None = None,
) -> None:
    rendered_lines = normalize_lines_for_write(path, lines, kind)
    rendered = "\n".join(rendered_lines)
    if rendered_lines:
        rendered += "\n"

    if preserve_from is None:
        with path.open(
            "w", encoding="utf-8", errors="surrogateescape", newline="\n"
        ) as stream:
            stream.write(rendered)
        return

    current = preserve_from.read_text(
        encoding="utf-8", errors="surrogateescape"
    ).replace("\r\n", "\n").replace("\r", "\n")
    if current == rendered:
        return

    target_stat = preserve_from.stat()
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=f".{preserve_from.name}.metadata.", dir=preserve_from.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(
            descriptor, "w", encoding="utf-8", errors="surrogateescape", newline="\n"
        ) as stream:
            stream.write(rendered)
        os.chmod(temporary_path, stat.S_IMODE(target_stat.st_mode))
        try:
            os.chown(temporary_path, target_stat.st_uid, target_stat.st_gid)
        except PermissionError:
            pass
        os.replace(temporary_path, preserve_from)
    finally:
        temporary_path.unlink(missing_ok=True)


def is_ignored_line(line: str) -> bool:
    stripped = line.lstrip()
    return not stripped or stripped.startswith("#")


def metadata_key(line: str, kind: MetadataKind) -> str | None:
    if is_ignored_line(line):
        return None
    fields = line.split()
    if not fields:
        return None
    key = fields[0]
    if kind == "contexts":
        key = key.replace("\\", "")
    return key


def replace_first_field(line: str, replacement: str) -> str:
    fields = line.split(maxsplit=1)
    if not fields:
        raise MetadataError("元数据条目缺少路径字段")
    return replacement if len(fields) == 1 else f"{replacement} {fields[1]}"


def prefix_matches(key: str, prefix: str, *, regex_boundaries: bool = False) -> bool:
    if key == prefix:
        return True
    if not key.startswith(prefix):
        return False
    remainder = key[len(prefix) :]
    if not remainder:
        return True
    allowed = {"/"}
    if regex_boundaries:
        allowed.update({"(", "["})
    return remainder[0] in allowed


def keyed_patch(
    lines: Iterable[str], kind: MetadataKind, patch_prefix: str | None = None
) -> OrderedDict[str, str]:
    patch: OrderedDict[str, str] = OrderedDict()
    for line in lines:
        key = metadata_key(line, kind)
        if key is None:
            continue
        if patch_prefix is not None and not key.startswith(patch_prefix):
            continue
        patch[key] = line
    return patch


def merge_metadata(
    patch_lines: Iterable[str],
    target_lines: Iterable[str],
    kind: MetadataKind,
    patch_prefix: str | None = None,
) -> list[str]:
    patch = keyed_patch(patch_lines, kind, patch_prefix)
    emitted_keys: set[str] = set()
    merged: list[str] = []

    for line in target_lines:
        key = metadata_key(line, kind)
        if key is None:
            merged.append(line)
            continue
        if key in emitted_keys:
            continue
        merged.append(patch.get(key, line))
        emitted_keys.add(key)

    for key, line in patch.items():
        if key not in emitted_keys:
            merged.append(line)
            emitted_keys.add(key)
    return merged


def remove_prefix(lines: Iterable[str], kind: MetadataKind, prefix: str) -> list[str]:
    emitted_keys: set[str] = set()
    filtered: list[str] = []
    for line in lines:
        key = metadata_key(line, kind)
        if key is None:
            filtered.append(line)
            continue
        if prefix_matches(key, prefix, regex_boundaries=kind == "contexts"):
            continue
        if key not in emitted_keys:
            filtered.append(line)
            emitted_keys.add(key)
    return filtered


def validate_relative_path(value: str) -> None:
    path = PurePosixPath(value)
    if (
        not value
        or value.startswith("/")
        or value.endswith("/")
        or "\\" in value
        or any(character.isspace() for character in value)
        or any(part in {"", ".", ".."} for part in path.parts)
        or str(path) != value
    ):
        raise MetadataError(f"来源清单路径不安全：{value}")


def validate_partition_mapping(source_root: str, target_root: str) -> None:
    if target_root in {"mi_odm", "mi_vendor"}:
        raise MetadataError(f"来源标记目录不能作为最终目标分区：{target_root}")
    expected = {"mi_odm": "odm", "mi_vendor": "vendor"}.get(source_root)
    if expected is not None and target_root != expected:
        raise MetadataError(f"来源标记 {source_root} 只能映射到最终分区：{expected}")


def validate_prefix(kind: MetadataKind, prefix: str) -> list[str]:
    if kind == "contexts":
        if not prefix.startswith("/"):
            raise MetadataError(f"contexts 路径前缀必须以 / 开头：{prefix}")
        value = prefix[1:]
    else:
        if prefix.startswith("/"):
            raise MetadataError(f"fsconfig 路径前缀不能以 / 开头：{prefix}")
        value = prefix
    validate_relative_path(value)
    return value.split("/")


def parse_manifest(path: Path) -> list[str]:
    relative_paths: list[str] = []
    seen: set[str] = set()
    for line_number, line in enumerate(read_lines(path), start=1):
        if is_ignored_line(line):
            continue
        fields = line.split()
        if len(fields) != 2 or fields[0] not in {"replace", "missing"}:
            raise MetadataError(f"来源清单格式错误：{path}:{line_number}")
        relative_path = fields[1]
        validate_relative_path(relative_path)
        if relative_path in seen:
            raise MetadataError(f"来源清单存在重复路径：{relative_path}")
        seen.add(relative_path)
        relative_paths.append(relative_path)
    if not relative_paths:
        raise MetadataError(f"来源清单为空：{path}")
    return relative_paths


def translate_manifest(
    source_lines: Iterable[str],
    manifest_paths: Iterable[str],
    kind: MetadataKind,
    source_prefix: str,
    target_prefix: str,
) -> list[str]:
    source_parts = validate_prefix(kind, source_prefix)
    target_parts = validate_prefix(kind, target_prefix)
    if len(source_parts) != 1 or len(target_parts) != 1:
        raise MetadataError("清单迁移只能使用分区根前缀")
    validate_partition_mapping(source_parts[0], target_parts[0])

    wanted = OrderedDict(
        (f"{source_prefix}/{relative_path}", None) for relative_path in manifest_paths
    )
    translated: OrderedDict[str, str] = OrderedDict()
    found: set[str] = set()
    for line in source_lines:
        key = metadata_key(line, kind)
        if key is None or key not in wanted:
            continue
        raw_path = line.split(maxsplit=1)[0]
        if not raw_path.startswith(source_prefix):
            continue
        target_path = f"{target_prefix}{raw_path[len(source_prefix):]}"
        target_key = target_path.replace("\\", "") if kind == "contexts" else target_path
        translated[target_key] = replace_first_field(line, target_path)
        found.add(key)

    missing = [path for path in wanted if path not in found]
    if missing:
        raise MetadataError("原包元数据缺少来源清单路径：" + "、".join(missing))
    return list(translated.values())


def translate_prefix(
    source_lines: Iterable[str],
    kind: MetadataKind,
    source_prefix: str,
    target_prefix: str,
) -> list[str]:
    source_parts = validate_prefix(kind, source_prefix)
    target_parts = validate_prefix(kind, target_prefix)
    validate_partition_mapping(source_parts[0], target_parts[0])

    translated: OrderedDict[str, str] = OrderedDict()
    for line in source_lines:
        key = metadata_key(line, kind)
        if key is None or not prefix_matches(
            key, source_prefix, regex_boundaries=kind == "contexts"
        ):
            continue
        raw_path = line.split(maxsplit=1)[0]
        if not raw_path.startswith(source_prefix):
            continue
        target_path = f"{target_prefix}{raw_path[len(source_prefix):]}"
        target_key = target_path.replace("\\", "") if kind == "contexts" else target_path
        translated[target_key] = replace_first_field(line, target_path)
    if not translated:
        raise MetadataError(f"原包 {kind} 中没有待转换路径：{source_prefix}")
    return list(translated.values())


def command_merge(args: argparse.Namespace) -> None:
    patch = Path(args.patch)
    target = Path(args.target)
    merged = merge_metadata(
        read_lines(patch), read_lines(target), args.kind, args.patch_prefix
    )
    write_lines(target, merged, args.kind, preserve_from=target)


def command_remove_prefix(args: argparse.Namespace) -> None:
    target = Path(args.target)
    validate_prefix(args.kind, args.prefix)
    filtered = remove_prefix(read_lines(target), args.kind, args.prefix)
    write_lines(target, filtered, args.kind, preserve_from=target)


def command_translate_manifest(args: argparse.Namespace) -> None:
    translated = translate_manifest(
        read_lines(Path(args.source)),
        parse_manifest(Path(args.manifest)),
        args.kind,
        args.source_prefix,
        args.target_prefix,
    )
    write_lines(Path(args.output), translated, args.kind)


def command_translate_prefix(args: argparse.Namespace) -> None:
    translated = translate_prefix(
        read_lines(Path(args.source)),
        args.kind,
        args.source_prefix,
        args.target_prefix,
    )
    write_lines(Path(args.output), translated, args.kind)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    merge_parser = subparsers.add_parser("merge", help="按路径合并并去重元数据")
    merge_parser.add_argument("--kind", choices=("contexts", "fsconfig"), required=True)
    merge_parser.add_argument("--patch", required=True)
    merge_parser.add_argument("--target", required=True)
    merge_parser.add_argument("--patch-prefix")
    merge_parser.set_defaults(handler=command_merge)

    remove_parser = subparsers.add_parser("remove-prefix", help="删除路径及其子路径元数据")
    remove_parser.add_argument("--kind", choices=("contexts", "fsconfig"), required=True)
    remove_parser.add_argument("--target", required=True)
    remove_parser.add_argument("--prefix", required=True)
    remove_parser.set_defaults(handler=command_remove_prefix)

    manifest_parser = subparsers.add_parser(
        "translate-manifest", help="按来源清单转换分区元数据"
    )
    manifest_parser.add_argument("--kind", choices=("contexts", "fsconfig"), required=True)
    manifest_parser.add_argument("--source", required=True)
    manifest_parser.add_argument("--manifest", required=True)
    manifest_parser.add_argument("--source-prefix", required=True)
    manifest_parser.add_argument("--target-prefix", required=True)
    manifest_parser.add_argument("--output", required=True)
    manifest_parser.set_defaults(handler=command_translate_manifest)

    prefix_parser = subparsers.add_parser(
        "translate-prefix", help="按路径前缀转换分区元数据"
    )
    prefix_parser.add_argument("--kind", choices=("contexts", "fsconfig"), required=True)
    prefix_parser.add_argument("--source", required=True)
    prefix_parser.add_argument("--source-prefix", required=True)
    prefix_parser.add_argument("--target-prefix", required=True)
    prefix_parser.add_argument("--output", required=True)
    prefix_parser.set_defaults(handler=command_translate_prefix)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    try:
        args.handler(args)
    except (MetadataError, OSError) as error:
        print(f"! 分区元数据工具：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
