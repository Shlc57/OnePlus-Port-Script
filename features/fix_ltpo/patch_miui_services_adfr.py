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
import hashlib
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import zipfile
from pathlib import Path
from typing import NoReturn


PATCH_DIR = Path(__file__).resolve().parent
RUS_TOOL = PATCH_DIR / "adfr_rus.py"
APKTOOL_JAR = Path("/snap/apktool/current/apktool.jar")
CLASS_PATH = Path("com/android/server/display/DisplayManagerServiceImpl.smali")
AOD_CLASS_PATH = Path("com/android/server/display/DisplayFeatureManagerServiceImpl.smali")
HELPER_SIGNATURE = ".method public sendOplusAdfrRusConfig()V"
# Previous revisions emitted package-private or private helpers. Both are
# accepted only as exact upgrade states and are rewritten to the public form.
LEGACY_HELPER_SIGNATURE = ".method sendOplusAdfrRusConfig()V"
LEGACY_PRIVATE_HELPER_SIGNATURE = ".method private sendOplusAdfrRusConfig()V"
HELPER_START = "OPLUS_ADFR_RUS_LOADER sha256="
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
# This is the only pre-count-slot payload accepted for an in-place upgrade.
# The current payload may also be present in the older synchronous helper;
# that exact module state is upgraded to the queued-handler form below.
LEGACY_PAYLOAD_DIGEST = "b43873c9b18b17849d0558cc21b9efdf5be011ff79ecf496a1cab5c6cdf36479"
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


def sha256_stream(entry: zipfile.ZipExtFile) -> str:
    digest = hashlib.sha256()
    for chunk in iter(lambda: entry.read(1024 * 1024), b""):
        digest.update(chunk)
    return digest.hexdigest()


def archive_entries_snapshot(jar_path: Path) -> list[str]:
    with zipfile.ZipFile(jar_path) as archive:
        return sorted(info.filename for info in archive.infolist())


def archive_content_snapshot(jar_path: Path, excluded_entry: str) -> list[tuple[object, ...]]:
    snapshot: list[tuple[object, ...]] = []
    with zipfile.ZipFile(jar_path) as archive:
        for index, info in enumerate(archive.infolist()):
            if info.filename == excluded_entry:
                continue
            with archive.open(info) as entry:
                snapshot.append(
                    (
                        index,
                        json.dumps(info.filename, ensure_ascii=True),
                        info.compress_type,
                        info.file_size,
                        info.CRC,
                        sha256_stream(entry),
                    )
                )
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


def expected_payload_digest(rus_xml: Path) -> str:
    output = run_command(
        [sys.executable, str(RUS_TOOL), "--validate", str(rus_xml)], capture=True
    ).strip()
    match = re.fullmatch(r"length=225 sha256_le_i32=([0-9a-f]{64})", output)
    if match is None:
        fail(f"ADFR RUS 载荷校验输出异常：{output}")
    return match.group(1)


def generated_helper(rus_xml: Path, expected_digest: str) -> str:
    helper = run_command(
        [sys.executable, str(RUS_TOOL), "--smali-method", str(rus_xml)], capture=True
    )
    if helper.count(HELPER_SIGNATURE) != 1:
        fail("生成的 ADFR helper 方法数量异常")
    if helper.count(f"{HELPER_START}{expected_digest}") != 1:
        fail("生成的 ADFR helper payload 标记不匹配")
    if helper.count(ASYNC_MARKER) != 1:
        fail("生成的 ADFR helper 异步标记数量异常")
    if helper.count(HELPER_END) != 1:
        fail("生成的 ADFR helper 结束标记数量异常")
    return helper.rstrip()


def smali_patch_state(text: str, expected_digest: str) -> str:
    markers = re.findall(r"OPLUS_ADFR_RUS_LOADER sha256=([0-9a-f]{64})", text)
    counts = {
        "method": (
            text.count(HELPER_SIGNATURE)
            + text.count(LEGACY_HELPER_SIGNATURE)
            + text.count(LEGACY_PRIVATE_HELPER_SIGNATURE)
        ),
        "new_method": text.count(HELPER_SIGNATURE),
        "legacy_method": text.count(LEGACY_HELPER_SIGNATURE),
        "legacy_private_method": text.count(LEGACY_PRIVATE_HELPER_SIGNATURE),
        "start": len(markers),
        "async": text.count(ASYNC_MARKER),
        "boot_call": text.count(BOOT_CALL_LINE),
        "boot_block": text.count(BOOT_BLOCK),
        "runnable_direct": text.count(RUNNABLE_CALL_DIRECT),
        "runnable_virtual": text.count(RUNNABLE_CALL_VIRTUAL),
    }
    if not markers and not any(counts.values()):
        return "original"
    if counts["method"] == 1 and counts["start"] == 1 and counts["async"] == 1 and counts["boot_call"] == 0 and counts["boot_block"] == 1:
        if markers[0] == expected_digest:
            if counts["new_method"] == 1:
                return "patched" if counts["runnable_virtual"] == 1 else "patched_unsafe"
            if counts["legacy_private_method"] == 1:
                return "patched_private"
            if counts["legacy_method"] == 1:
                return "patched_unsafe"
    if counts["method"] == 1 and counts["start"] == 1 and counts["async"] == 0 and counts["boot_call"] == 1 and counts["boot_block"] == 0:
        if markers[0] in {expected_digest, LEGACY_PAYLOAD_DIGEST}:
            return "legacy_sync"
    if markers and markers[0] == LEGACY_PAYLOAD_DIGEST:
        fail(
            "旧 ADFR payload 处于非完整可升级状态："
            f"method={counts['method']} boot_call={counts['boot_call']} boot_block={counts['boot_block']}"
        )
    if markers and markers[0] != expected_digest:
        fail(
            "miui-services.jar 已含不同 ADFR RUS payload："
            f"existing={markers[0]} expected={expected_digest}"
        )
    details = ", ".join(f"{name}={value}" for name, value in counts.items())
    fail(f"ADFR Smali 处于部分补丁状态：{details}")


def patch_smali(
    smali_path: Path,
    helper: str,
    expected_digest: str,
    state: str,
    runnable_path: Path | None = None,
) -> None:
    try:
        original = smali_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"读取 DisplayManagerServiceImpl Smali 失败：{error}")
    if state not in {"original", "legacy_sync", "patched_private", "patched_unsafe"}:
        fail("ADFR Smali 未处于可注入或可升级状态")
    if smali_patch_state(original, expected_digest) != state:
        fail("ADFR Smali 在注入前状态发生变化")
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
        helper_matches = []
        for signature in (
            HELPER_SIGNATURE,
            LEGACY_HELPER_SIGNATURE,
            LEGACY_PRIVATE_HELPER_SIGNATURE,
        ):
            signature_start = original.find(signature)
            if signature_start >= 0:
                helper_matches.append(signature_start)
        if len(helper_matches) != 1:
            fail("无法唯一定位旧 ADFR helper 方法")
        helper_start = helper_matches[0]
        helper_end = original.find("\n.end method", helper_start)
        if helper_end < 0 or helper_end >= method_start:
            fail("无法唯一定位旧 ADFR helper 方法")
        helper_end += len("\n.end method")
        old_helper = original[helper_start:helper_end]
        old_digest = re.findall(r"OPLUS_ADFR_RUS_LOADER sha256=([0-9a-f]{64})", old_helper)
        if len(old_digest) != 1 or old_digest[0] not in {expected_digest, LEGACY_PAYLOAD_DIGEST}:
            fail("旧 ADFR helper 不含可升级的本模块 payload 标记")
        updated = original[:helper_start] + helper + original[helper_end:]
        if updated.count(BOOT_CALL_LINE) != 1:
            fail("旧 ADFR boot call 数量异常")
        updated = updated.replace(BOOT_CALL_LINE, BOOT_BLOCK, 1)
        if LEGACY_PAYLOAD_DIGEST in updated:
            fail("旧 ADFR helper digest 在升级后残留")
    elif state in {"patched_private", "patched_unsafe"}:
        helper_matches = []
        for signature in (
            LEGACY_PRIVATE_HELPER_SIGNATURE,
            LEGACY_HELPER_SIGNATURE,
        ):
            signature_start = original.find(signature)
            if signature_start >= 0:
                helper_matches.append((signature, signature_start))
        if len(helper_matches) != 1:
            fail("无法唯一定位旧 ADFR helper")
        legacy_signature, helper_start = helper_matches[0]
        updated = original[:helper_start] + original[helper_start:].replace(
            legacy_signature, HELPER_SIGNATURE, 1
        )
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
    if smali_patch_state(verification_text, expected_digest) != "patched":
        fail("注入后的 ADFR Smali 状态异常")
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


def patch_jar(jar_path: Path, rus_xml: Path) -> None:
    expected_digest = expected_payload_digest(rus_xml)
    helper = generated_helper(rus_xml, expected_digest)
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
            ["java", "-jar", str(APKTOOL_JAR), "d", "-j", "1", "-f", "-r", "-o", str(decoded), str(jar_path)]
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
        state = smali_patch_state(original_text + "\n" + runnable_text, expected_digest)
        aod_state = full_aod_patch_state(aod_original_text)
        if state == "patched" and aod_state == "original":
            run_command(["unzip", "-tq", str(jar_path)])
            log("SKIP：OnePlus ADFR RUS loader 已存在，且未发现旧 Full-AOD replay")
            return

        if state != "patched":
            action = "升级" if state in {"legacy_sync", "patched_private"} else "注入"
            log(f"{action} OnePlus ADFR RUS loader（目标 DEX：{dex_entry}，payload：{expected_digest}）")
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
        if state != "patched":
            patch_smali(smali_path, helper, expected_digest, state, runnable_path)
        aod_removed = False
        if aod_state == "patched":
            log(f"移除旧 Full-AOD replay（目标 DEX：{dex_entry}）")
            aod_removed = remove_full_aod_smali(aod_smali_path, aod_state)
        log("回编译目标 DEX")
        run_command(
            ["java", "-jar", str(APKTOOL_JAR), "b", "-j", "1", str(decoded), "-o", str(rebuilt)]
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
            ["java", "-jar", str(APKTOOL_JAR), "d", "-j", "1", "-f", "-r", "-o", str(verify), str(patched)]
        )
        verify_smali = verify / relative_smali_path
        if not verify_smali.is_file():
            fail("生成 JAR 解包中缺少 DisplayManagerServiceImpl")
        verify_runnable = verify / relative_smali_path.parent / f"{RUNNABLE_CLASS}.smali"
        verify_text = verify_smali.read_text(encoding="utf-8")
        if verify_runnable.is_file():
            verify_text += "\n" + verify_runnable.read_text(encoding="utf-8")
        if smali_patch_state(verify_text, expected_digest) != "patched":
            fail("生成 JAR 中的 ADFR loader 复核失败")
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
    parser.add_argument("jar", type=Path, metavar="miui-services.jar")
    parser.add_argument("xml", type=Path, metavar="adfr2minfps.xml")
    arguments = parser.parse_args()
    try:
        if not APKTOOL_JAR.is_file():
            fail(f"找不到 Apktool JAR：{APKTOOL_JAR}")
        for command in ("java", "unzip", "zip"):
            if shutil.which(command) is None:
                fail(f"缺少依赖命令：{command}")
        jar_path = require_regular_file(arguments.jar, "miui-services.jar")
        rus_xml = require_regular_file(arguments.xml, "OnePlus ADFR RUS XML")
        patch_jar(jar_path, rus_xml)
    except PatchError as error:
        print(f"[!] {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
