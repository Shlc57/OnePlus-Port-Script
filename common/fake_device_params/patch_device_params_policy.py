#!/usr/bin/env python3
"""Inject and validate the dedicated device-parameter SELinux domain."""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


DOMAIN_TYPE = "fake_device_params"
EXEC_TYPE = "fake_device_params_exec"
BEGIN_MARKER = ";; BEGIN common/fake_device_params dedicated domain"
END_MARKER = ";; END common/fake_device_params dedicated domain"


class PolicyError(ValueError):
    """Raised when the target CIL cannot be patched deterministically."""


def require_fragment(fragment: str) -> None:
    lines = fragment.splitlines()
    if not lines or lines[0] != BEGIN_MARKER or lines[-1] != END_MARKER:
        raise PolicyError("专用 policy 片段缺少固定边界标记")
    if fragment.count(BEGIN_MARKER) != 1 or fragment.count(END_MARKER) != 1:
        raise PolicyError("专用 policy 片段边界标记重复")
    for type_name in (DOMAIN_TYPE, EXEC_TYPE):
        if f"(type {type_name})" not in lines:
            raise PolicyError(f"专用 policy 片段缺少类型：{type_name}")


def merge_fragment(policy: str, fragment: str) -> str:
    begin_count = policy.count(BEGIN_MARKER)
    end_count = policy.count(END_MARKER)
    if begin_count == 0 and end_count == 0:
        for type_name in (DOMAIN_TYPE, EXEC_TYPE):
            if re.search(rf"^\(type {re.escape(type_name)}\)$", policy, re.MULTILINE):
                raise PolicyError(f"目标 policy 已存在未受补丁管理的类型：{type_name}")
        return policy.rstrip("\n") + "\n\n" + fragment
    if begin_count != 1 or end_count != 1:
        raise PolicyError("目标 policy 中专用域边界标记不完整或重复")

    lines = policy.splitlines(keepends=True)
    begin_index = next(
        index for index, line in enumerate(lines) if line.rstrip("\n") == BEGIN_MARKER
    )
    end_index = next(
        index for index, line in enumerate(lines) if line.rstrip("\n") == END_MARKER
    )
    if end_index < begin_index:
        raise PolicyError("目标 policy 中专用域边界标记顺序错误")
    existing_fragment = "".join(lines[begin_index : end_index + 1])
    if existing_fragment != fragment:
        raise PolicyError("已有 fake_device_params policy 与当前补丁不一致")
    return policy


def find_app_data_neverallow_subject(policy: str) -> str:
    matched_classes: dict[str, set[str]] = {}
    pattern = re.compile(
        r"^\(neverallow (?P<subject>base_typeattr_[0-9]+) "
        r"system_app_data_file \((?P<class_name>file|dir) "
        r"\((?P<permissions>[^)]*)\)\)\)$"
    )
    for line in policy.splitlines():
        match = pattern.fullmatch(line)
        if not match:
            continue
        permissions = set(match.group("permissions").split())
        if {"create", "unlink", "open"}.issubset(permissions):
            subject = match.group("subject")
            matched_classes.setdefault(subject, set()).add(match.group("class_name"))

    candidates = [
        subject
        for subject, class_names in matched_classes.items()
        if {"file", "dir"}.issubset(class_names)
    ]
    if len(candidates) != 1:
        raise PolicyError(
            "无法唯一定位禁止 native domain 访问 system_app_data_file 的 neverallow"
        )
    return candidates[0]


def exempt_dedicated_domain(policy: str, subject: str) -> str:
    pattern = re.compile(
        rf"^\(typeattributeset {re.escape(subject)} "
        r"\(and \(domain\s*\) \(not \((?P<exceptions>[^)]*)\)\)\)\)$",
        re.MULTILINE,
    )
    matches = list(pattern.finditer(policy))
    if len(matches) != 1:
        raise PolicyError(f"无法唯一定位 neverallow subject 定义：{subject}")

    match = matches[0]
    exceptions = match.group("exceptions").split()
    required_existing = {"appdomain", "artd", "installd", "system_server"}
    if not required_existing.issubset(exceptions):
        raise PolicyError(f"neverallow subject 例外集合不符合当前平台结构：{subject}")
    if DOMAIN_TYPE in exceptions:
        return policy

    exceptions.append(DOMAIN_TYPE)
    replacement = (
        f"(typeattributeset {subject} (and (domain ) "
        f"(not ({' '.join(exceptions)} ))))"
    )
    return policy[: match.start()] + replacement + policy[match.end() :]


def patch_policy(policy: str, fragment: str) -> str:
    require_fragment(fragment)
    subject = find_app_data_neverallow_subject(policy)
    policy = exempt_dedicated_domain(policy, subject)
    return merge_fragment(policy, fragment)


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--policy", required=True, type=Path)
    parser.add_argument("--fragment", required=True, type=Path)
    output_group = parser.add_mutually_exclusive_group(required=True)
    output_group.add_argument("--output", type=Path)
    output_group.add_argument("--check", action="store_true")
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        policy = args.policy.read_text(encoding="utf-8")
        fragment = args.fragment.read_text(encoding="utf-8")
        patched = patch_policy(policy, fragment)
        if args.check:
            if patched != policy:
                raise PolicyError("目标 policy 尚未完整应用专用域或 neverallow 例外")
        else:
            assert args.output is not None
            args.output.write_text(patched, encoding="utf-8", newline="\n")
    except (OSError, UnicodeError, PolicyError) as error:
        print(f"! 设备参数 SELinux policy：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
