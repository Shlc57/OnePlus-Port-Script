#!/usr/bin/env python3
"""契约测试：补丁脚本里 mktemp 出来的临时文件必须进入某条回收路径。

`AGENTS.md` 要求临时文件由 trap 或明确清理路径回收。历史上 ``features/fix_nfc_tms_bridge``
漏登记了一个 ``mktemp`` 变量，导致 ``WORKSPACE/config/`` 里每跑一次就残留一个 0600 的随机名
文件；产物内容不受影响，但脏树会掩盖同类漏项，所以这里做静态兜底。

判定为「已回收」的形态：
  1. 变量出现在 ``temporary_files+=( … )`` / ``temporary_directories+=( … )`` 之类的追加块内；
  2. 变量所在的逻辑语句（已合并反斜杠续行）里含 ``rm`` / ``mv`` / ``find … -delete`` /
     ``remove_path_if_exists`` / ``remove_file_if_exists`` / ``_install_generated_file``；
``mktemp`` 赋值行本身以及只写入不删除的语句（``printf > "$x"``、``cp -p … "$x"``）不算回收。

用法：``python3 tools/test_temp_file_cleanup.py [目录]``
"""

from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

MKTEMP_ASSIGN_RE = re.compile(
    r'^[ \t]*(?:local[ \t]+)?([A-Za-z_][A-Za-z0-9_]*)="[^\n]*\$\(mktemp'
)
ARRAY_APPEND_RE = re.compile(r'^[ \t]*([A-Za-z_][A-Za-z0-9_]*)\+=\(')
RECLAIM_RE = re.compile(
    r'\b(?:rm|mv|rmdir|find|remove_path_if_exists|remove_file_if_exists'
    r'|_install_generated_file)\b'
)


def logical_statements(lines: list[str]) -> list[tuple[int, str]]:
    """返回 (起始行号, 合并续行后的语句)，行号从 1 开始。"""

    statements: list[tuple[int, str]] = []
    buffer: list[str] = []
    start = 0
    for index, line in enumerate(lines, start=1):
        stripped = line.rstrip()
        if not buffer and not stripped.strip():
            continue
        if stripped.endswith("\\"):
            if not buffer:
                start = index
            buffer.append(stripped[:-1])
            continue
        if buffer:
            buffer.append(stripped)
            statements.append((start, " ".join(part.strip() for part in buffer)))
            buffer = []
        else:
            statements.append((index, stripped))
    if buffer:
        statements.append((start, " ".join(part.strip() for part in buffer)))
    return statements


def array_append_blocks(lines: list[str]) -> list[str]:
    """收集所有 ``name+=( … )`` 块的内容，兼容单行与跨行写法。"""

    blocks: list[str] = []
    index = 0
    while index < len(lines):
        match = ARRAY_APPEND_RE.match(lines[index])
        if match:
            tail = lines[index][match.end() :]
            close = re.search(r"\)\s*$", tail)
            if close:
                # 单行形式：temporary_files+=("$a" "$b")
                blocks.append(tail[: close.start()])
            else:
                body: list[str] = []
                index += 1
                while index < len(lines) and not re.match(r"^[ \t]*\)", lines[index]):
                    body.append(lines[index])
                    index += 1
                blocks.append("\n".join(body))
        index += 1
    return blocks


def referenced(text: str, variable: str) -> bool:
    return re.search(r"\$\{?" + re.escape(variable) + r"\}?\b", text) is not None


def find_leaks(path: Path) -> list[tuple[int, str]]:
    lines = path.read_text(encoding="utf-8").splitlines()
    blocks = array_append_blocks(lines)
    statements = logical_statements(lines)
    leaks: list[tuple[int, str]] = []
    for line_no, line in enumerate(lines, start=1):
        match = MKTEMP_ASSIGN_RE.match(line)
        if not match:
            continue
        variable = match.group(1)
        if any(referenced(block, variable) for block in blocks):
            continue
        reclaimed = False
        for start, statement in statements:
            if start == line_no:
                continue
            if referenced(statement, variable) and RECLAIM_RE.search(statement):
                reclaimed = True
                break
        if not reclaimed:
            leaks.append((line_no, variable))
    return leaks


def apply_scripts(root: Path) -> list[Path]:
    try:
        result = subprocess.run(
            ["rg", "--files", "-g", "apply.sh", str(root)],
            capture_output=True,
            text=True,
            check=True,
        )
        return [Path(line) for line in result.stdout.split() if line]
    except (OSError, subprocess.CalledProcessError):
        return sorted(root.rglob("apply.sh"))


def main(argv: list[str]) -> int:
    root = Path(argv[1]) if len(argv) > 1 else Path(__file__).resolve().parents[1]
    scripts = apply_scripts(root)
    failures: list[tuple[Path, int, str]] = []
    for script in scripts:
        for line_no, variable in find_leaks(script):
            failures.append((script, line_no, variable))
    if failures:
        print(
            f"FAIL: {len(failures)} 处 mktemp 临时文件没有任何回收路径",
            file=sys.stderr,
        )
        for script, line_no, variable in failures:
            print(f"  {script}:{line_no}  ${variable}", file=sys.stderr)
        return 1
    print(f"temp file cleanup contract passed（扫描 {len(scripts)} 个 apply.sh）")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
