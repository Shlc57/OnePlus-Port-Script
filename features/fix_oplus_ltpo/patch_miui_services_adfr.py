#!/usr/bin/env python3
"""Safely inject the OnePlus ADFR RUS loader into miui-services.jar.

The first revision of this patcher also rewrote
``DisplayFeatureManagerServiceImpl.init()`` to replay a cached Full-AOD state.
That replay is deliberately no longer installed: it can race the real AOD
power transition and leave the physical TE at 120 Hz.  An already patched JAR
is still upgraded, but only when its ``init()`` body is an exact copy of that
old payload; the old body is restored to the stock implementation.
"""

from __future__ import annotations

import argparse
import datetime
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
import zlib
from pathlib import Path
from typing import NoReturn


PATCH_DIR = Path(__file__).resolve().parent
RUS_TOOL = PATCH_DIR / "adfr_rus.py"
CLASS_PATH = Path("com/android/server/display/DisplayManagerServiceImpl.smali")
AOD_CLASS_PATH = Path("com/android/server/display/DisplayFeatureManagerServiceImpl.smali")
HELPER_SIGNATURE = ".method public sendOplusAdfrRusConfig()V"
# Previous revisions emitted package-private or private helpers. Both are
# accepted only as exact upgrade states and are rewritten to the public form.
LEGACY_HELPER_SIGNATURE = ".method sendOplusAdfrRusConfig()V"
LEGACY_PRIVATE_HELPER_SIGNATURE = ".method private sendOplusAdfrRusConfig()V"
LOADER_MARKER = "OPLUS_ADFR_RUS_LOADER_V2"
HELPER_END = "# OPLUS_ADFR_RUS_LOADER_END"
ASYNC_MARKER = "OPLUS_ADFR_RUS_LOADER_ASYNC_V1"
RUNNABLE_CLASS = "DisplayManagerServiceImpl$OplusAdfrRusRunnable"
RUNNABLE_CALL_DIRECT = (
    "invoke-direct {v0}, "
    "Lcom/android/server/display/DisplayManagerServiceImpl;->sendOplusAdfrRusConfig()V"
)
RUNNABLE_CALL_VIRTUAL = (
    "invoke-virtual {v0}, "
    "Lcom/android/server/display/DisplayManagerServiceImpl;->sendOplusAdfrRusConfig()V"
)
BOOT_METHOD = ".method public onBootCompleted()V"
BOOT_CALL = (
    "invoke-direct {p0}, Lcom/android/server/display/DisplayManagerServiceImpl;"
    "->sendOplusAdfrRusConfig()V"
)
BOOT_CALL_LINE = f"    {BOOT_CALL}"
BOOT_BLOCK = """    iget-object v0, p0, Lcom/android/server/display/DisplayManagerServiceImpl;->mHandler:Landroid/os/Handler;

    new-instance v1, Lcom/android/server/display/DisplayManagerServiceImpl$OplusAdfrRusRunnable;

    invoke-direct {v1, p0}, Lcom/android/server/display/DisplayManagerServiceImpl$OplusAdfrRusRunnable;-><init>(Lcom/android/server/display/DisplayManagerServiceImpl;)V

    invoke-virtual {v0, v1}, Landroid/os/Handler;->post(Ljava/lang/Runnable;)Z"""
AOD_INIT_METHOD = ".method public init(Lcom/android/server/display/DisplayFeatureManagerInternal;)V"
# The following constants describe the retired replay payload.  They are kept
# solely so an already-built JAR can be identified and repaired safely; the
# payload is never emitted into a new JAR.
AOD_REPLAY_MARKER = "OPLUS_ADFR_FULL_AOD_REPLAY_V1"
AOD_REPLAY_INVOKE = (
    "invoke-virtual {p0, v1, v2}, "
    "Lcom/android/server/display/DisplayFeatureManagerServiceImpl;->updateFullAodState(IZ)V"
)
AOD_REPLAY_BLOCK = f"""    const-string/jumbo v2, \"{AOD_REPLAY_MARKER}\"

    iput-object p1, p0, Lcom/android/server/display/DisplayFeatureManagerServiceImpl;->mDisplayFeatureInternal:Lcom/android/server/display/DisplayFeatureManagerInternal;

    if-eqz p1, :oplus_full_aod_replay_done

    iget-object v0, p0, Lcom/android/server/display/DisplayFeatureManagerServiceImpl;->mIsFullAod:[Z

    if-eqz v0, :oplus_full_aod_replay_done

    const/4 v1, 0x0

    :oplus_full_aod_replay_loop
    array-length v2, v0

    if-ge v1, v2, :oplus_full_aod_replay_done

    aget-boolean v2, v0, v1

    {AOD_REPLAY_INVOKE}

    add-int/lit8 v1, v1, 0x1

    goto :oplus_full_aod_replay_loop

    :oplus_full_aod_replay_done"""
AOD_ORIGINAL_METHOD = f"""{AOD_INIT_METHOD}
    .locals 0
    .param p1, \"displayFeatureInternal\"    # Lcom/android/server/display/DisplayFeatureManagerInternal;

    .line 20
    iput-object p1, p0, Lcom/android/server/display/DisplayFeatureManagerServiceImpl;->mDisplayFeatureInternal:Lcom/android/server/display/DisplayFeatureManagerInternal;

    .line 21
    return-void
.end method"""
AOD_REPLAY_METHOD = (
    AOD_INIT_METHOD
    + "\n"
    + "    .locals 3\n"
    + "    .param p1, \"displayFeatureInternal\"    # Lcom/android/server/display/DisplayFeatureManagerInternal;\n\n"
    + AOD_REPLAY_BLOCK
    + "\n\n    return-void\n.end method"
)

# The helper's payload is protocol data generated from the project XML.  Its
# identity is therefore described by stable code shape and Binder constants,
# never by a digest or a release-specific byte offset.  The legacy marker
# matcher exists only to recognize helpers emitted by pre-V2 revisions while
# upgrading an already patched JAR; it deliberately accepts any non-empty old
# marker value and never compares that value with the current XML.  In
# particular, do not require a 64-character hexadecimal token: that would
# retain a release/hash-shaped identity contract even though the value is
# only a legacy implementation marker.
LEGACY_LOADER_VALUE_RE = re.compile(r"^OPLUS_ADFR_RUS_LOADER\s+\S.*$")
LOADER_METHOD_RE = re.compile(
    r"(?m)^[ \t]*\.method[ \t]+(?:(?:public|private)[ \t]+)?"
    r"sendOplusAdfrRusConfig\(\)V[ \t]*$"
)
METHOD_DECL_RE = re.compile(r"^\.method(?:\s+.*)?$")
METHOD_END_RE = re.compile(r"^\.end method$")
LOADER_REQUIRED_PATTERNS: tuple[re.Pattern[str], ...] = (
    re.compile(r"(?m)^[ \t]*const/(?:4|16)\s+v\d+,\s+0xe1\s*$"),
    re.compile(r"(?m)^[ \t]*new-array\s+v\d+,\s+v\d+,\s+\[I\s*$"),
    re.compile(r"(?m)^[ \t]*fill-array-data\s+v\d+,\s+:[A-Za-z0-9_$.-]+\s*$"),
    re.compile(
        r'(?m)^[ \t]*const-string(?:/jumbo)?\s+v\d+,\s+"'
        r'vendor\.oplus\.hardware\.displaypanelfeature\.IDisplayPanelFeature/default"\s*$'
    ),
    re.compile(
        r'(?m)^[ \t]*const-string(?:/jumbo)?\s+v\d+,\s+"'
        r'vendor\.oplus\.hardware\.displaypanelfeature\.IDisplayPanelFeature"\s*$'
    ),
    re.compile(r"(?m)^[ \t]*const/(?:4|16)\s+v\d+,\s+0xea\s*$"),
    re.compile(
        r"(?m)^[ \t]*invoke-virtual\s+\{v\d+,\s+v\d+\},\s+"
        r"Landroid/os/Parcel;->writeIntArray\(\[I\)V\s*$"
    ),
    re.compile(r"(?m)^[ \t]*const/(?:4|16)\s+v\d+,\s+0x2\s*$"),
    re.compile(
        r"(?m)^[ \t]*invoke-interface\s+\{v\d+,\s+v\d+,\s+v\d+,\s+v\d+,\s+v\d+\},\s+"
        r"Landroid/os/IBinder;->transact\(ILandroid/os/Parcel;Landroid/os/Parcel;I\)Z\s*$"
    ),
)


class PatchError(RuntimeError):
    """A safe-to-report patching failure."""


def fail(message: str) -> NoReturn:
    raise PatchError(message)


def log(message: str) -> None:
    print(f"[*] {message}")


def run_command(arguments: list[str], *, cwd: Path | None = None, capture: bool = False) -> str:
    try:
        completed = subprocess.run(
            arguments,
            cwd=cwd,
            check=True,
            text=True,
            stdout=subprocess.PIPE if capture else None,
            stderr=subprocess.PIPE if capture else None,
        )
    except (OSError, subprocess.CalledProcessError) as error:
        details = ""
        if isinstance(error, subprocess.CalledProcessError):
            stderr = error.stderr or ""
            details = f"：{stderr.strip()}" if stderr.strip() else ""
        fail(f"命令失败：{' '.join(arguments)}{details}")
    return completed.stdout or ""


def require_regular_file(path: Path, description: str) -> Path:
    if path.is_symlink():
        fail(f"不支持使用符号链接{description}：{path}")
    if not path.is_file():
        fail(f"找不到{description}：{path}")
    return path.resolve()


def _strip_smali_comment(line: str) -> str:
    """Strip a Smali comment without treating ``#`` inside a string as one."""

    quoted = False
    escaped = False
    for index, character in enumerate(line):
        if character == '"' and not escaped:
            quoted = not quoted
        elif character == "#" and not quoted:
            return line[:index]
        escaped = character == "\\" and not escaped
        if character != "\\":
            escaped = False
    return line


def _active_lines(text: str) -> list[str]:
    return [
        active
        for raw_line in text.splitlines()
        if (active := _strip_smali_comment(raw_line).strip())
    ]


def _line_offsets(text: str):
    offset = 0
    for raw_line in text.splitlines(keepends=True):
        yield offset, raw_line
        offset += len(raw_line)
    if not text.endswith(("\n", "\r")):
        return


def _method_span_from_start(text: str, start: int) -> tuple[int, int]:
    offset = start
    for raw_line in text[start:].splitlines(keepends=True):
        code = _strip_smali_comment(raw_line).strip()
        if code == ".end method":
            return start, offset + len(raw_line.rstrip("\r\n"))
        offset += len(raw_line)
    fail("无法定位方法结尾")


def _normalized_declaration(value: str) -> str:
    return " ".join(value.split())


def archive_entries_snapshot(jar_path: Path) -> list[str]:
    with zipfile.ZipFile(jar_path) as archive:
        return sorted(info.filename for info in archive.infolist())


def archive_content_snapshot(jar_path: Path, excluded_entry: str) -> list[tuple[int, str, int, bytes]]:
    """Capture non-target member contents without package identity metadata.

    Comparing the bytes directly keeps the guard useful across base/original
    OTA revisions.  A digest, CRC, or expected member size would turn those
    unrelated package details into an implicit release whitelist.
    """

    snapshot: list[tuple[int, str, int, bytes]] = []
    with zipfile.ZipFile(jar_path) as archive:
        for index, info in enumerate(archive.infolist()):
            if info.filename == excluded_entry:
                continue
            snapshot.append((index, info.filename, info.compress_type, archive.read(info)))
    return snapshot


def dex_entry_for_smali(relative_smali_path: Path) -> str:
    root = relative_smali_path.parts[0]
    if root == "smali":
        return "classes.dex"
    match = re.fullmatch(r"smali_classes([0-9]+)", root)
    if match is None:
        fail(f"无法从 Smali 目录识别目标 DEX：{root}")
    return f"classes{match.group(1)}.dex"


def find_class_smali(
    decoded_path: Path, class_path: Path, description: str
) -> tuple[Path, Path, str]:
    matches = list(decoded_path.glob(f"**/{class_path.as_posix()}"))
    if len(matches) != 1:
        fail(f"{description} 类数量异常：期望 1 个，实际 {len(matches)} 个")
    smali_path = matches[0]
    relative_path = smali_path.relative_to(decoded_path)
    return smali_path, relative_path, dex_entry_for_smali(relative_path)


def find_target_smali(decoded_path: Path) -> tuple[Path, Path, str]:
    return find_class_smali(decoded_path, CLASS_PATH, "DisplayManagerServiceImpl")


def extract_method(text: str, signature: str, description: str) -> tuple[int, int, str]:
    method_count = text.count(signature)
    if method_count != 1:
        fail(f"{description} 数量异常：期望 1 个，实际 {method_count} 个")
    method_start = text.find(signature)
    method_end = text.find("\n.end method", method_start)
    if method_start < 0 or method_end < 0:
        fail(f"无法定位{description}结尾")
    method_end += len("\n.end method")
    return method_start, method_end, text[method_start:method_end]


def extract_loader_method(text: str) -> tuple[int, int, str, str] | None:
    """Return the sole ADFR loader method and its declaration line.

    A method declaration is parsed as a Smali construct instead of searched as
    an arbitrary substring, so strings in comments or unrelated descriptors do
    not affect the state machine.
    """

    matches = list(LOADER_METHOD_RE.finditer(text))
    if len(matches) > 1:
        fail(f"ADFR helper 方法数量异常：期望最多 1 个，实际 {len(matches)} 个")
    if not matches:
        return None
    match = matches[0]
    method_end = text.find("\n.end method", match.start())
    if method_end < 0:
        fail("无法定位 ADFR helper 方法结尾")
    method_end += len("\n.end method")
    return match.start(), method_end, text[match.start() : method_end], match.group(0)


def _legacy_loader_marker_count(method: str) -> int:
    """Count pre-V2 payload markers without treating their value as identity."""

    values = re.findall(r'"([^"]*)"', method)
    return sum(1 for value in values if LEGACY_LOADER_VALUE_RE.fullmatch(value))


def _loader_semantics_valid(method: str) -> bool:
    """Check the stable protocol instructions shared by all loader revisions."""

    if any(not pattern.search(method) for pattern in LOADER_REQUIRED_PATTERNS):
        return False
    array_blocks = re.findall(r"\.array-data\s+4(.*?)\.end array-data", method, re.S)
    return len(array_blocks) == 1


def extract_loader_payload(method: str) -> list[int]:
    """Extract the int[225] protocol vector from a loader helper.

    This is used only to decide whether a currently installed project helper
    already carries the XML-derived vector.  It is a content comparison, not a
    persisted file hash or size identity.
    """

    blocks = re.findall(r"\.array-data\s+4(.*?)\.end array-data", method, re.S)
    if len(blocks) != 1:
        fail("ADFR helper 的 array-data 区块数量异常")
    values: list[int] = []
    for raw_line in blocks[0].splitlines():
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r"(-?)(?:0x([0-9a-fA-F]+)|([0-9]+))", line)
        if match is None:
            fail(f"ADFR helper array-data 包含无法识别的值：{line}")
        sign, hexadecimal, decimal = match.groups()
        value = int(hexadecimal or decimal, 16 if hexadecimal is not None else 10)
        values.append(-value if sign else value)
    if len(values) != 225:
        fail(f"ADFR helper payload 长度异常：期望 225，实际 {len(values)}")
    return values


def loader_payload_matches(method: str, generated_helper: str) -> bool:
    """Compare two helpers by their generated protocol vector."""

    try:
        return extract_loader_payload(method) == extract_loader_payload(generated_helper)
    except PatchError:
        return False


def normalized_smali_method(method: str) -> list[str]:
    """Return instruction-level text with apktool-generated labels normalized."""

    labels: dict[str, str] = {}

    def normalize_label(match: re.Match[str]) -> str:
        label = match.group(0)
        if label not in labels:
            labels[label] = f":L{len(labels)}"
        return labels[label]

    normalized: list[str] = []
    for raw_line in method.splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        # Apktool may add source/debug directives while rebuilding a DEX.
        # They do not belong to the executable payload we are identifying.
        if line.startswith(
            (".line ", ".param ", ".prologue", ".local ", ".restart ", ".end local ")
        ):
            continue
        # A label is preceded by whitespace/comma.  Do not mistake the
        # colon in a Smali type descriptor (``field:Lcom/...``) for a label.
        line = re.sub(
            r"(?<![A-Za-z0-9_$]):[A-Za-z_$][A-Za-z0-9_$.-]*",
            normalize_label,
            line,
        )
        normalized.append(line)
    return normalized


def full_aod_patch_state(text: str) -> str:
    """Classify the retired Full-AOD replay without accepting partial edits."""

    _, _, method = extract_method(
        text, AOD_INIT_METHOD, "DisplayFeatureManagerServiceImpl.init"
    )
    marker_count = method.count(AOD_REPLAY_MARKER)
    invoke_count = method.count(AOD_REPLAY_INVOKE)
    if marker_count == 0 and invoke_count == 0:
        return "original"
    if (
        marker_count == 1
        and invoke_count == 1
        and normalized_smali_method(method) == normalized_smali_method(AOD_REPLAY_METHOD)
    ):
        return "patched"
    fail(
        "Full-AOD replay Smali 处于部分补丁状态或与本模块载荷不符："
        f"marker={marker_count} invoke={invoke_count}"
    )


def remove_full_aod_smali(smali_path: Path, state: str) -> bool:
    """Remove one exact legacy replay and restore the stock ``init`` body."""

    try:
        original = smali_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"读取 DisplayFeatureManagerServiceImpl Smali 失败：{error}")
    if full_aod_patch_state(original) != state:
        fail("DisplayFeatureManagerServiceImpl Smali 在注入前状态发生变化")
    if state == "original":
        return False
    method_start, method_end, method = extract_method(
        original, AOD_INIT_METHOD, "DisplayFeatureManagerServiceImpl.init"
    )
    if normalized_smali_method(method) != normalized_smali_method(AOD_REPLAY_METHOD):
        fail("现有 Full-AOD replay 不是本模块的精确旧载荷，拒绝覆盖")
    updated = original[:method_start] + AOD_ORIGINAL_METHOD + original[method_end:]
    if full_aod_patch_state(updated) != "original":
        fail("移除后的 DisplayFeatureManagerServiceImpl.init 状态异常")
    original_mode = stat.S_IMODE(smali_path.stat().st_mode)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="", dir=smali_path.parent, delete=False
        ) as temporary_file:
            temporary_path = Path(temporary_file.name)
            temporary_file.write(updated)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.chmod(temporary_path, original_mode)
        os.replace(temporary_path, smali_path)
    except OSError as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        fail(f"移除 Full-AOD replay Smali 失败：{error}")
    return True


def generated_helper(rus_xml: Path) -> str:
    helper = run_command(
        [sys.executable, str(RUS_TOOL), "--smali-method", str(rus_xml)], capture=True
    )
    if helper.count(HELPER_SIGNATURE) != 1:
        fail("生成的 ADFR helper 方法数量异常")
    if helper.count(LOADER_MARKER) != 1:
        fail("生成的 ADFR helper 版本标记数量异常")
    if helper.count(ASYNC_MARKER) != 1:
        fail("生成的 ADFR helper 异步标记数量异常")
    if helper.count(HELPER_END) != 1:
        fail("生成的 ADFR helper 结束标记数量异常")
    if not _loader_semantics_valid(helper):
        fail("生成的 ADFR helper 指令语义不完整")
    extract_loader_payload(helper)
    return helper.rstrip()


def smali_patch_state(text: str) -> str:
    """Classify the ADFR helper using structural and instruction evidence.

    No payload value is compared here.  This lets an OTA-rebased JAR carry a
    different XML-derived vector while still being recognized as a previous
    project patch.  The caller separately compares the vector to the current
    project asset when deciding whether a rebuild is needed.
    """

    loader = extract_loader_method(text)
    current_marker_count = text.count(LOADER_MARKER)
    legacy_marker_count = (
        _legacy_loader_marker_count(loader[2]) if loader is not None else 0
    )
    counts = {
        "method": 1 if loader is not None else 0,
        "new_method": int(loader is not None and loader[3] == HELPER_SIGNATURE),
        "legacy_method": int(loader is not None and loader[3] == LEGACY_HELPER_SIGNATURE),
        "legacy_private_method": int(
            loader is not None and loader[3] == LEGACY_PRIVATE_HELPER_SIGNATURE
        ),
        "current_marker": current_marker_count,
        "legacy_marker": legacy_marker_count,
        "async": text.count(ASYNC_MARKER),
        "boot_call": text.count(BOOT_CALL_LINE),
        "boot_block": text.count(BOOT_BLOCK),
        "runnable_direct": text.count(RUNNABLE_CALL_DIRECT),
        "runnable_virtual": text.count(RUNNABLE_CALL_VIRTUAL),
    }
    if loader is None and not any(
        counts[name]
        for name in ("current_marker", "legacy_marker", "async", "boot_call", "boot_block")
    ):
        return "original"

    if loader is None:
        fail("ADFR Smali 含补丁痕迹但缺少完整 helper 方法")
    if not _loader_semantics_valid(loader[2]):
        fail("ADFR helper 指令语义不完整或已损坏")
    has_current_marker = current_marker_count == 1
    has_legacy_marker = legacy_marker_count == 1
    if current_marker_count > 1 or legacy_marker_count > 1:
        fail("ADFR helper 版本标记数量异常")

    # New asynchronous form: one queued boot block and one Runnable call.
    if (
        counts["async"] == 1
        and counts["boot_call"] == 0
        and counts["boot_block"] == 1
        and counts["runnable_direct"] + counts["runnable_virtual"] == 1
        and (has_current_marker or has_legacy_marker)
    ):
        if counts["new_method"] == 1 and counts["runnable_virtual"] == 1 and has_current_marker:
            return "patched"
        if counts["legacy_private_method"] == 1:
            return "patched_private"
        if counts["legacy_method"] == 1 or counts["runnable_direct"] == 1:
            return "patched_unsafe"

    # Earlier synchronous form: direct boot invocation and no async marker.
    if (
        counts["async"] == 0
        and counts["boot_call"] == 1
        and counts["boot_block"] == 0
        and has_legacy_marker
    ):
        return "legacy_sync"

    details = ", ".join(f"{name}={value}" for name, value in counts.items())
    fail(f"ADFR Smali 处于部分补丁状态：{details}")


def patch_smali(
    smali_path: Path,
    helper: str,
    state: str,
    runnable_path: Path | None = None,
) -> None:
    try:
        original = smali_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"读取 DisplayManagerServiceImpl Smali 失败：{error}")
    state_text = original
    if runnable_path is not None and runnable_path.is_file():
        state_text += "\n" + runnable_path.read_text(encoding="utf-8")
    if smali_patch_state(state_text) != state:
        fail("ADFR Smali 在注入前状态发生变化")
    if state not in {"original", "legacy_sync", "patched", "patched_private", "patched_unsafe"}:
        fail("ADFR Smali 未处于可注入或可升级状态")
    if original.count(BOOT_METHOD) != 1:
        fail("DisplayManagerServiceImpl.onBootCompleted 数量异常")
    method_start = original.find(BOOT_METHOD)
    method_end = original.find("\n.end method", method_start)
    if method_end < 0:
        fail("无法定位 onBootCompleted 结尾")
    method_end += len("\n.end method")
    method = original[method_start:method_end]
    return_anchor = "    return-void\n.end method"
    if method.count(return_anchor) != 1:
        fail("onBootCompleted 的 return-void 落点不唯一")
    if state == "original":
        updated_method = method.replace(
            return_anchor, f"{BOOT_BLOCK}\n\n{return_anchor}", 1
        )
        updated = original[:method_start] + helper + "\n\n" + updated_method + original[method_end:]
    elif state == "legacy_sync":
        # Smali comments are not retained in the DEX produced by Apktool, so
        # the BEGIN/END comments emitted by the generator cannot delimit an
        # already-patched JAR.  The state check above has already established
        # one helper method, one legacy DEX string marker, and one boot call.
        # Locate exactly that private method and reject any other placement.
        loader = extract_loader_method(original)
        if loader is None:
            fail("无法唯一定位旧 ADFR helper 方法")
        helper_start, helper_end, _old_helper, _signature = loader
        updated = original[:helper_start] + helper + original[helper_end:]
        if updated.count(BOOT_CALL_LINE) != 1:
            fail("旧 ADFR boot call 数量异常")
        updated = updated.replace(BOOT_CALL_LINE, BOOT_BLOCK, 1)
    elif state in {"patched", "patched_private", "patched_unsafe"}:
        loader = extract_loader_method(original)
        if loader is None:
            fail("无法唯一定位旧 ADFR helper")
        helper_start, helper_end, old_helper, _signature = loader
        if state == "patched" and loader_payload_matches(old_helper, helper):
            updated = original
        else:
            updated = original[:helper_start] + helper + original[helper_end:]
    else:
        updated = original
    if state in {"patched_private", "patched_unsafe"}:
        if runnable_path is None or not runnable_path.is_file():
            fail("缺少既有 ADFR Runnable，不能修复跨类调用")
        runnable_text = runnable_path.read_text(encoding="utf-8")
        direct_count = runnable_text.count(RUNNABLE_CALL_DIRECT)
        virtual_count = runnable_text.count(RUNNABLE_CALL_VIRTUAL)
        if direct_count == 1 and virtual_count == 0:
            runnable_path.write_text(
                runnable_text.replace(RUNNABLE_CALL_DIRECT, RUNNABLE_CALL_VIRTUAL, 1),
                encoding="utf-8",
            )
        elif direct_count != 0 or virtual_count != 1:
            fail("既有 ADFR Runnable 调用点数量异常")
    verification_text = updated
    if runnable_path is not None and runnable_path.is_file():
        verification_text += "\n" + runnable_path.read_text(encoding="utf-8")
    if smali_patch_state(verification_text) != "patched":
        fail("注入后的 ADFR Smali 状态异常")
    if updated == original:
        return
    original_mode = stat.S_IMODE(smali_path.stat().st_mode)
    temporary_path: Path | None = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="", dir=smali_path.parent, delete=False
        ) as temporary_file:
            temporary_path = Path(temporary_file.name)
            temporary_file.write(updated)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.chmod(temporary_path, original_mode)
        os.replace(temporary_path, smali_path)
    except OSError as error:
        if temporary_path is not None:
            temporary_path.unlink(missing_ok=True)
        fail(f"写入 ADFR Smali 失败：{error}")


def extract_rebuilt_dex(rebuilt_jar: Path, dex_entry: str, dex_path: Path, source_jar: Path) -> None:
    with zipfile.ZipFile(rebuilt_jar) as rebuilt:
        try:
            rebuilt_info = rebuilt.getinfo(dex_entry)
        except KeyError:
            fail(f"回编译结果中缺少 {dex_entry}")
        with rebuilt.open(rebuilt_info) as entry, dex_path.open("wb") as output:
            shutil.copyfileobj(entry, output)
    if dex_path.stat().st_size == 0:
        fail(f"生成的 {dex_entry} 为空")
    with zipfile.ZipFile(source_jar) as source:
        try:
            original_info = source.getinfo(dex_entry)
        except KeyError:
            fail(f"原 JAR 中缺少 {dex_entry}")
    if original_info.compress_type != zipfile.ZIP_STORED:
        fail(f"当前版本要求 {dex_entry} 使用 ZIP_STORED，实际为 {original_info.compress_type}")
    timestamp = datetime.datetime(*original_info.date_time).timestamp()
    mode = stat.S_IMODE(original_info.external_attr >> 16) or 0o644
    os.chmod(dex_path, mode)
    os.utime(dex_path, (timestamp, timestamp))


def restore_file_metadata(source: Path, target: Path) -> None:
    source_stat = source.stat()
    try:
        os.chown(target, source_stat.st_uid, source_stat.st_gid)
        os.chmod(target, stat.S_IMODE(source_stat.st_mode))
        os.utime(target, ns=(source_stat.st_atime_ns, source_stat.st_mtime_ns))
    except OSError as error:
        fail(f"无法恢复原 miui-services.jar 文件属性：{error}")


def replace_atomically(source: Path, target: Path) -> None:
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".miui-services.jar.adfr.", dir=target.parent
    )
    temporary_path = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as output, source.open("rb") as input_file:
            shutil.copyfileobj(input_file, output)
            output.flush()
            os.fsync(output.fileno())
        restore_file_metadata(target, temporary_path)
        os.replace(temporary_path, target)
    except OSError as error:
        temporary_path.unlink(missing_ok=True)
        fail(f"原子替换 miui-services.jar 失败：{error}")


def patch_jar(jar_path: Path, rus_xml: Path, apktool_command: list[str]) -> None:
    helper = generated_helper(rus_xml)
    with tempfile.TemporaryDirectory(prefix="fix-ltpo-adfr-rus.") as temporary_name:
        work_dir = Path(temporary_name)
        decoded = work_dir / "decoded"
        rebuilt = work_dir / "rebuilt.jar"
        dex_dir = work_dir / "dex"
        patched = work_dir / "miui-services.jar.patched"
        verify = work_dir / "verify"

        log("记录原 miui-services.jar 归档内容")
        entries_before = archive_entries_snapshot(jar_path)
        log("反编译 miui-services.jar")
        run_command(
            apktool_command + ["d", "-j", "1", "-f", "-r", "-o", str(decoded), str(jar_path)]
        )
        smali_path, relative_smali_path, dex_entry = find_target_smali(decoded)
        aod_smali_path, aod_relative_smali_path, aod_dex_entry = find_class_smali(
            decoded, AOD_CLASS_PATH, "DisplayFeatureManagerServiceImpl"
        )
        if aod_dex_entry != dex_entry:
            fail(
                "ADFR 与旧 Full-AOD replay 位于不同 DEX，当前升级写回边界不支持："
                f"{dex_entry} 与 {aod_dex_entry}"
            )
        if entries_before.count(dex_entry) != 1:
            fail(f"原 JAR 中 {dex_entry} 数量异常：期望 1 个，实际 {entries_before.count(dex_entry)} 个")
        non_target_before = archive_content_snapshot(jar_path, dex_entry)
        original_text = smali_path.read_text(encoding="utf-8")
        aod_original_text = aod_smali_path.read_text(encoding="utf-8")
        runnable_path = decoded / relative_smali_path.parent / f"{RUNNABLE_CLASS}.smali"
        runnable_text = runnable_path.read_text(encoding="utf-8") if runnable_path.is_file() else ""
        state_text = original_text + "\n" + runnable_text
        state = smali_patch_state(state_text)
        aod_state = full_aod_patch_state(aod_original_text)
        loader_matches_current = False
        if state == "patched":
            loader = extract_loader_method(original_text)
            if loader is not None:
                loader_matches_current = loader_payload_matches(loader[2], helper)
        if state == "patched" and loader_matches_current and aod_state == "original":
            run_command(["unzip", "-tq", str(jar_path)])
            log("SKIP：OnePlus ADFR RUS loader 已存在，且未发现旧 Full-AOD replay")
            return

        if state != "patched" or not loader_matches_current:
            action = "升级" if state != "original" else "注入"
            log(f"{action} OnePlus ADFR RUS loader（目标 DEX：{dex_entry}）")
        if state in {"original", "legacy_sync"} and runnable_path.exists():
            fail(f"目标 DEX 已存在同名 ADFR Runnable：{runnable_path}")
        if state in {"original", "legacy_sync"}:
            runnable_path.write_text(
            f""".class Lcom/android/server/display/{RUNNABLE_CLASS};
.super Ljava/lang/Object;
.implements Ljava/lang/Runnable;

.field final synthetic this$0:Lcom/android/server/display/DisplayManagerServiceImpl;

.method constructor <init>(Lcom/android/server/display/DisplayManagerServiceImpl;)V
    .locals 0
    iput-object p1, p0, Lcom/android/server/display/{RUNNABLE_CLASS};->this$0:Lcom/android/server/display/DisplayManagerServiceImpl;
    invoke-direct {{p0}}, Ljava/lang/Object;-><init>()V
    return-void
.end method

.method public run()V
    .locals 1
    iget-object v0, p0, Lcom/android/server/display/{RUNNABLE_CLASS};->this$0:Lcom/android/server/display/DisplayManagerServiceImpl;
    invoke-virtual {{v0}}, Lcom/android/server/display/DisplayManagerServiceImpl;->sendOplusAdfrRusConfig()V
    return-void
.end method
""",
                encoding="utf-8",
            )
        if state != "patched" or not loader_matches_current:
            patch_smali(smali_path, helper, state, runnable_path)
        aod_removed = False
        if aod_state == "patched":
            log(f"移除旧 Full-AOD replay（目标 DEX：{dex_entry}）")
            aod_removed = remove_full_aod_smali(aod_smali_path, aod_state)
        log("回编译目标 DEX")
        run_command(
            apktool_command + ["b", "-j", "1", "-o", str(rebuilt), str(decoded)]
        )
        dex_dir.mkdir()
        dex_path = dex_dir / dex_entry
        extract_rebuilt_dex(rebuilt, dex_entry, dex_path, jar_path)

        log(f"仅将 {dex_entry} 增量写入原 JAR 副本")
        shutil.copy2(jar_path, patched)
        run_command(["zip", "-q", "-X", "-0", str(patched), dex_entry], cwd=dex_dir)
        run_command(["unzip", "-tq", str(patched)])
        with zipfile.ZipFile(patched) as archive, dex_path.open("rb") as expected:
            if archive.read(dex_entry) != expected.read():
                fail(f"{dex_entry} 未正确写入 JAR")
        if archive_entries_snapshot(patched) != entries_before:
            fail("更新后 JAR 的归档条目列表发生变化")
        if archive_content_snapshot(patched, dex_entry) != non_target_before:
            fail("更新后存在目标 DEX 之外的条目内容变化")

        log("复核生成 JAR 中的 ADFR Smali")
        run_command(
            apktool_command + ["d", "-j", "1", "-f", "-r", "-o", str(verify), str(patched)]
        )
        verify_smali = verify / relative_smali_path
        if not verify_smali.is_file():
            fail("生成 JAR 解包中缺少 DisplayManagerServiceImpl")
        verify_runnable = verify / relative_smali_path.parent / f"{RUNNABLE_CLASS}.smali"
        verify_text = verify_smali.read_text(encoding="utf-8")
        if verify_runnable.is_file():
            verify_text += "\n" + verify_runnable.read_text(encoding="utf-8")
        if smali_patch_state(verify_text) != "patched":
            fail("生成 JAR 中的 ADFR loader 复核失败")
        verify_loader = extract_loader_method(verify_smali.read_text(encoding="utf-8"))
        if verify_loader is None or not loader_payload_matches(verify_loader[2], helper):
            fail("生成 JAR 中的 ADFR payload 与当前项目 XML 不一致")
        verify_aod_smali = verify / aod_relative_smali_path
        if not verify_aod_smali.is_file():
            fail("生成 JAR 解包中缺少 DisplayFeatureManagerServiceImpl")
        if full_aod_patch_state(verify_aod_smali.read_text(encoding="utf-8")) != "original":
            fail("生成 JAR 中的 DisplayFeatureManagerServiceImpl.init 仍含旧 Full-AOD replay")
        restore_file_metadata(jar_path, patched)
        replace_atomically(patched, jar_path)
    if state != "patched":
        log(f"APPLY：OnePlus ADFR RUS loader 已注入：{jar_path}")
    if aod_removed:
        log(f"APPLY：已移除旧 Full-AOD replay：{jar_path}")
    log("已保留目标 DEX 之外的全部 JAR 条目；调用方必须清理旧 profile、OAT 与 FS-Verity 元数据")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--apktool-command", action="append", required=True)
    parser.add_argument("jar", type=Path, metavar="miui-services.jar")
    parser.add_argument("xml", type=Path, metavar="adfr2minfps.xml")
    arguments = parser.parse_args()
    try:
        for command in ("unzip", "zip"):
            if shutil.which(command) is None:
                fail(f"缺少依赖命令：{command}")
        jar_path = require_regular_file(arguments.jar, "miui-services.jar")
        rus_xml = require_regular_file(arguments.xml, "OnePlus ADFR RUS XML")
        patch_jar(jar_path, rus_xml, arguments.apktool_command)
    except PatchError as error:
        print(f"[!] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
