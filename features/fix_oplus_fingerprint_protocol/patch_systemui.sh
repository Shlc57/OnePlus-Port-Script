#!/usr/bin/env bash
set -Eeuo pipefail

CLASS_PATH='com/miui/keyguard/biometrics/fod/MiuiGxzwIconView.smali'
PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PORT_ROOT=$(cd -- "$PATCHER_DIR/../.." && pwd -P)
SIGNING_BLOCK_TOOL="$PORT_ROOT/common/apk_signing_block.py"

WORK_DIR=''
REPLACEMENT_PATH=''

log() {
	printf '[*] %s\n' "$*"
}

fail() {
	printf '[!] %s\n' "$*" >&2
	exit 1
}

cleanup() {
	if [[ -n "$REPLACEMENT_PATH" && -e "$REPLACEMENT_PATH" ]]; then
		rm -f -- "$REPLACEMENT_PATH"
	fi
	if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
		find "$WORK_DIR" -depth -delete >/dev/null 2>&1 || true
	fi
}

require_command() {
	command -v "$1" >/dev/null 2>&1 || fail "缺少依赖命令：$1"
}

resolve_apktool() {
	if [[ -n "${APKTOOL_JAR:-}" ]]; then
		[[ -r "$APKTOOL_JAR" ]] || fail "无法读取 APKTOOL_JAR：$APKTOOL_JAR"
		require_command java
		APKTOOL_COMMAND=(java -jar "$APKTOOL_JAR")
	elif [[ -r /snap/apktool/current/apktool.jar ]]; then
		require_command java
		APKTOOL_COMMAND=(java -jar /snap/apktool/current/apktool.jar)
	elif command -v apktool >/dev/null 2>&1; then
		APKTOOL_COMMAND=(apktool)
	else
		fail "缺少 Apktool"
	fi
}

resolve_zipalign() {
	local sdk_root candidate

	if [[ -n "${ZIPALIGN:-}" ]]; then
		[[ -x "$ZIPALIGN" ]] || fail "ZIPALIGN 不可执行：$ZIPALIGN"
		ZIPALIGN_COMMAND=$ZIPALIGN
		return
	fi
	if command -v zipalign >/dev/null 2>&1; then
		ZIPALIGN_COMMAND=$(command -v zipalign)
		return
	fi

	for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "${ANDROID_SDK:-}"; do
		[[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]] || continue
		candidate=$(
			find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 \
				-type f -name zipalign -perm -u+x -print |
				LC_ALL=C sort -V |
				tail -n 1
		)
		if [[ -n "$candidate" ]]; then
			ZIPALIGN_COMMAND=$candidate
			return
		fi
	done

	fail "缺少 zipalign；可通过 ZIPALIGN 指定可执行文件"
}

# Compare the current input and output archives directly.  No source-package
# hash, size, CRC, or other release-specific identity snapshot is persisted.
# Reading every non-target member also verifies the ZIP CRC for this run.

archive_entry_count() {
	local apk_file=$1
	local requested_entry=$2

	python3 - "$apk_file" "$requested_entry" <<'PY'
import sys
import zipfile


apk_path, requested_entry = sys.argv[1:]
try:
	with zipfile.ZipFile(apk_path) as archive:
		infos = archive.infolist()
		names = [info.filename for info in infos]
		if len(names) != len(set(names)):
			raise ValueError("ZIP contains duplicate member names")
		print(sum(info.filename == requested_entry for info in infos))
except (
	OSError,
	EOFError,
	IndexError,
	MemoryError,
	OverflowError,
	RuntimeError,
	ValueError,
	zipfile.BadZipFile,
	zipfile.LargeZipFile,
) as error:
	print(f"无法读取 APK 归档：{error}", file=sys.stderr)
	raise SystemExit(1)
PY
}

compare_archive_contract() {
	local before_apk=$1
	local after_apk=$2
	local excluded_entry=${3:-}

	python3 - "$before_apk" "$after_apk" "$excluded_entry" <<'PY'
import sys
import zipfile
import zlib


before_path, after_path, excluded_entry = sys.argv[1:]


def fail(message):
	print(f"归档契约校验失败：{message}", file=sys.stderr)
	raise SystemExit(1)


def open_archive(path):
	try:
		archive = zipfile.ZipFile(path)
		infos = archive.infolist()
	except (
		OSError,
		EOFError,
		IndexError,
		MemoryError,
		OverflowError,
		RuntimeError,
		ValueError,
		zipfile.BadZipFile,
		zipfile.LargeZipFile,
		zlib.error,
	) as error:
		fail(f"无法读取 {path}: {error}")
	names = [info.filename for info in infos]
	if len(names) != len(set(names)):
		archive.close()
		fail(f"{path} 包含重复 ZIP 条目")
	return archive, infos


def contents_equal(before, before_info, after, after_info):
	try:
		with before.open(before_info) as before_entry, after.open(after_info) as after_entry:
			while True:
				before_chunk = before_entry.read(1024 * 1024)
				after_chunk = after_entry.read(1024 * 1024)
				if before_chunk != after_chunk:
					return False
				if not before_chunk:
					return True
	except (
		EOFError,
		IndexError,
		KeyError,
		MemoryError,
		NotImplementedError,
		OSError,
		OverflowError,
		RuntimeError,
		ValueError,
		zipfile.BadZipFile,
		zipfile.LargeZipFile,
		zlib.error,
	) as error:
		fail(f"条目 {before_info.filename!r} 内容读取失败：{error}")


before = after = None
try:
	before, before_infos = open_archive(before_path)
	after, after_infos = open_archive(after_path)
	if len(before_infos) != len(after_infos):
		fail(f"条目数量变化：{len(before_infos)} -> {len(after_infos)}")
	if excluded_entry:
		before_excluded = [info for info in before_infos if info.filename == excluded_entry]
		after_excluded = [info for info in after_infos if info.filename == excluded_entry]
		if len(before_excluded) != 1 or len(after_excluded) != 1:
			fail(f"目标条目 {excluded_entry!r} 数量异常")

	for index, (before_info, after_info) in enumerate(zip(before_infos, after_infos)):
		if before_info.filename != after_info.filename:
			fail(
				f"条目顺序或名称变化（位置 {index}: "
				f"{before_info.filename!r} -> {after_info.filename!r}）"
			)
		if (
			before_info.filename != excluded_entry
			and before_info.compress_type != after_info.compress_type
		):
			fail(
				f"条目压缩方式变化（{before_info.filename!r}: "
				f"{before_info.compress_type} -> {after_info.compress_type}）"
			)
		if before_info.filename == excluded_entry:
			continue
		if not contents_equal(before, before_info, after, after_info):
			fail(f"非目标条目内容变化：{before_info.filename!r}")
finally:
	if before is not None:
		before.close()
	if after is not None:
		after.close()
PY
}

find_target_dex_entry() {
	local apk_file=$1

	python3 - "$apk_file" <<'PY'
import re
import sys
import zipfile


apk_path = sys.argv[1]
class_descriptor = b"Lcom/miui/keyguard/biometrics/fod/MiuiGxzwIconView;"
matches = []

with zipfile.ZipFile(apk_path) as archive:
    for info in archive.infolist():
        if not re.fullmatch(r"classes(?:[0-9]+)?\.dex", info.filename):
            continue
        if class_descriptor in archive.read(info):
            matches.append(info.filename)

if len(matches) != 1:
    raise SystemExit(
        "[!] MiuiGxzwIconView 所在 DEX 数量异常：期望 1 个，实际 {} 个：{}".format(
            len(matches), ", ".join(matches) if matches else "无"
        )
    )

print(matches[0])
PY
}

smali_patch_state() {
	local smali_file=$1
	local mode=$2

	python3 - "$smali_file" "$mode" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path


class PatchError(Exception):
    pass


path = Path(sys.argv[1])
mode = sys.argv[2]
if mode not in {"check", "patch"}:
    raise SystemExit("[!] 无效的 Smali 操作模式")

method_pattern = re.compile(
    r"^\s*\.method\s+.*onTouch\(Landroid/view/View;"
    r"Landroid/view/MotionEvent;\)Z\s*$"
)
down_marker = 'const-string/jumbo v1, "OPLUS_FOD_RAW_TOUCH_DOWN"'
up_marker = 'const-string/jumbo v1, "OPLUS_FOD_RAW_TOUCH_UP"'
property_marker = 'const-string/jumbo v0, "persist.vendor.sys.fp.vendor"'
down_call = (
    "invoke-virtual {p0}, Lcom/miui/keyguard/biometrics/fod/"
    "MiuiGxzwIconView;->onTouchDown()V"
)
up_call = (
    "invoke-virtual {p0, v1}, Lcom/miui/keyguard/biometrics/fod/"
    "MiuiGxzwIconView;->onTouchUp(Z)V"
)


def find_method(lines):
    matches = []
    for start, line in enumerate(lines):
        if not method_pattern.match(line.rstrip("\r\n")):
            continue
        for end in range(start + 1, len(lines)):
            if re.match(r"^\s*\.end method\s*$", lines[end].rstrip("\r\n")):
                matches.append((start, end))
                break
        else:
            raise PatchError("onTouch 方法缺少 .end method")
    if len(matches) != 1:
        raise PatchError(
            "onTouch 方法数量异常：期望 1 个，实际 {} 个".format(len(matches))
        )
    return matches[0]


def normalize_instructions(block_lines):
    instructions = []
    for line in block_lines[1:-1]:
        normalized = line.split("#", 1)[0].strip()
        if not normalized or normalized.startswith(".") or normalized.startswith(":"):
            continue
        instructions.append(normalized)
    return instructions


def classify(block):
    counts = {
        "down_marker": block.count(down_marker),
        "up_marker": block.count(up_marker),
        "property_marker": block.count(property_marker),
        "down_call": block.count(down_call),
        "up_call": block.count(up_call),
    }
    expected = {
        "down_marker": 1,
        "up_marker": 1,
        "property_marker": 1,
        "down_call": 1,
        "up_call": 1,
    }
    if counts == expected and ".locals 3" in block:
        return "patched", counts
    if any(counts.values()):
        return "partial", counts
    return "original", counts


replacement = """.method public final onTouch(Landroid/view/View;Landroid/view/MotionEvent;)Z
    .locals 3

    const-string/jumbo v0, \"persist.vendor.sys.fp.vendor\"

    const-string v1, \"\"

    invoke-static {v0, v1}, Landroid/os/SystemProperties;->get(Ljava/lang/String;Ljava/lang/String;)Ljava/lang/String;

    move-result-object v0

    const-string/jumbo v1, \"oplus\"

    invoke-virtual {v1, v0}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z

    move-result v0

    if-eqz v0, :oplus_fod_raw_touch_return

    invoke-virtual {p2}, Landroid/view/MotionEvent;->getActionMasked()I

    move-result v0

    if-nez v0, :oplus_fod_raw_touch_check_up

    const-string v0, \"MiuiGxzwViewIcon\"

    const-string/jumbo v1, \"OPLUS_FOD_RAW_TOUCH_DOWN\"

    invoke-static {v0, v1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    invoke-virtual {p0}, Lcom/miui/keyguard/biometrics/fod/MiuiGxzwIconView;->onTouchDown()V

    goto :oplus_fod_raw_touch_return

    :oplus_fod_raw_touch_check_up
    const/4 v1, 0x1

    if-eq v0, v1, :oplus_fod_raw_touch_up

    const/4 v2, 0x3

    if-ne v0, v2, :oplus_fod_raw_touch_return

    :oplus_fod_raw_touch_up
    const-string v0, \"MiuiGxzwViewIcon\"

    const-string/jumbo v1, \"OPLUS_FOD_RAW_TOUCH_UP\"

    invoke-static {v0, v1}, Landroid/util/Log;->i(Ljava/lang/String;Ljava/lang/String;)I

    const/4 v1, 0x1

    invoke-virtual {p0, v1}, Lcom/miui/keyguard/biometrics/fod/MiuiGxzwIconView;->onTouchUp(Z)V

    :oplus_fod_raw_touch_return
    const/4 p0, 0x1

    return p0
.end method
"""

try:
    original_text = path.read_text(encoding="utf-8")
    lines = original_text.splitlines(keepends=True)
    start, end = find_method(lines)
    block = "".join(lines[start : end + 1])
    state, counts = classify(block)

    if state == "patched":
        print("patched 0")
        raise SystemExit(0)
    if state == "partial":
        details = ", ".join(f"{name}={value}" for name, value in counts.items())
        raise PatchError(f"onTouch 方法处于部分补丁状态：{details}")

    original_instructions = normalize_instructions(lines[start : end + 1])
    if original_instructions != ["const/4 p0, 0x1", "return p0"]:
        raise PatchError("onTouch 原始指令结构与当前支持版本不一致")
    if not any(
        re.match(r"^\s*\.locals\s+0\s*$", line.rstrip("\r\n"))
        for line in lines[start + 1 : end]
    ):
        raise PatchError("onTouch 原始寄存器声明与当前支持版本不一致")

    if mode == "check":
        print("original 0")
        raise SystemExit(0)

    newline = "\r\n" if lines[start].endswith("\r\n") else "\n"
    replacement_lines = replacement.replace("\n", newline).splitlines(keepends=True)
    lines[start : end + 1] = replacement_lines
    updated_text = "".join(lines)

    updated_lines = updated_text.splitlines(keepends=True)
    updated_start, updated_end = find_method(updated_lines)
    updated_block = "".join(updated_lines[updated_start : updated_end + 1])
    updated_state, updated_counts = classify(updated_block)
    if updated_state != "patched":
        details = ", ".join(
            f"{name}={value}" for name, value in updated_counts.items()
        )
        raise PatchError(f"修改后的 onTouch 校验失败：{details}")

    file_mode = stat.S_IMODE(path.stat().st_mode)
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as temporary_file:
            temporary_name = temporary_file.name
            temporary_file.write(updated_text)
            temporary_file.flush()
            os.fsync(temporary_file.fileno())
        os.chmod(temporary_name, file_mode)
        os.replace(temporary_name, path)
    except OSError:
        if temporary_name is not None:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
        raise

    print("patched 1")
except (OSError, UnicodeError, PatchError) as error:
    print(f"[!] 修改 MiuiGxzwIconView Smali 失败：{error}", file=sys.stderr)
    raise SystemExit(1)
PY
}

(( $# == 1 )) || fail "用法：$0 <MiuiSystemUI.apk>"
APK_PATH=$1

for command_name in basename cmp cp dirname find mkdir mktemp mv python3 rm sort tail unzip zip; do
	require_command "$command_name"
done
resolve_apktool
resolve_zipalign
[[ -r "$SIGNING_BLOCK_TOOL" ]] || fail "找不到 Signing Block 工具：$SIGNING_BLOCK_TOOL"

[[ -f "$APK_PATH" ]] || fail "找不到 MiuiSystemUI.apk：$APK_PATH"
[[ ! -L "$APK_PATH" ]] || fail "不支持修改符号链接 APK：$APK_PATH"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd)/$(basename -- "$APK_PATH")
APK_DIR=$(dirname -- "$APK_PATH")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fix-oplus-fod-systemui.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR="$WORK_DIR/decoded"
TARGET_ARCHIVE_DIR="$WORK_DIR/target-archive"
TARGET_ARCHIVE="$WORK_DIR/target.jar"
REBUILT_TARGET_ARCHIVE="$WORK_DIR/target-rebuilt.jar"
DEX_DIR="$WORK_DIR/dex"
PATCHED_APK="$WORK_DIR/MiuiSystemUI.apk.patched"
ALIGNED_APK="$WORK_DIR/MiuiSystemUI.apk.aligned"
SIGNING_BLOCK_BEFORE="$WORK_DIR/apk-signing-block.before"
SIGNING_BLOCK_AFTER="$WORK_DIR/apk-signing-block.after"

log "读取原 MiuiSystemUI.apk 归档"
SIGNING_BLOCK_PAIR_IDS=$(
	python3 "$SIGNING_BLOCK_TOOL" extract "$APK_PATH" "$SIGNING_BLOCK_BEFORE"
)
log "已保存原 APK Signing Block Pair IDs：$SIGNING_BLOCK_PAIR_IDS"

DEX_ENTRY=$(find_target_dex_entry "$APK_PATH")
DEX_ENTRY_COUNT=$(archive_entry_count "$APK_PATH" "$DEX_ENTRY")
(( DEX_ENTRY_COUNT == 1 )) ||
	fail "原 APK 中 $DEX_ENTRY 数量异常：期望 1 个，实际 $DEX_ENTRY_COUNT 个"

mkdir -p -- "$TARGET_ARCHIVE_DIR"
unzip -p "$APK_PATH" "$DEX_ENTRY" > "$TARGET_ARCHIVE_DIR/classes.dex" ||
	fail "无法从原 APK 提取 $DEX_ENTRY"
[[ -s "$TARGET_ARCHIVE_DIR/classes.dex" ]] || fail "提取的 $DEX_ENTRY 为空"
(
	cd -- "$TARGET_ARCHIVE_DIR"
	zip -q -0 "$TARGET_ARCHIVE" classes.dex
)

log "仅反编译包含 MiuiGxzwIconView 的 $DEX_ENTRY"
"${APKTOOL_COMMAND[@]}" d -j 1 -f -r -o "$DECODE_DIR" "$TARGET_ARCHIVE"

SMALI_FILE="$DECODE_DIR/smali/$CLASS_PATH"
[[ -f "$SMALI_FILE" ]] || fail "反编译结果中缺少 MiuiGxzwIconView：$SMALI_FILE"

read -r PATCH_STATE _ < <(smali_patch_state "$SMALI_FILE" check)
case "$PATCH_STATE" in
	patched)
		unzip -tq "$APK_PATH" >/dev/null || fail "已补丁 APK 完整性校验失败"
		"$ZIPALIGN_COMMAND" -c -P 16 4 "$APK_PATH" >/dev/null 2>&1 ||
			fail "已补丁 APK 未通过 zipalign 校验"
		log "SKIP：Oplus FOD 原始触摸动画触发已存在"
		exit 0
		;;
	original)
		;;
	*)
		fail "无法识别目标 Smali 状态：$PATCH_STATE"
		;;
esac

log "修改 MiuiGxzwIconView.onTouch（目标 DEX：$DEX_ENTRY）"
read -r PATCH_STATE CHANGED_COUNT < <(smali_patch_state "$SMALI_FILE" patch)
[[ "$PATCH_STATE" == patched && "$CHANGED_COUNT" == 1 ]] ||
	fail "修改后的 Smali 状态异常：state=$PATCH_STATE changed=$CHANGED_COUNT"

log "仅回编译目标 DEX：$DEX_ENTRY"
"${APKTOOL_COMMAND[@]}" b -j 1 "$DECODE_DIR" -o "$REBUILT_TARGET_ARCHIVE"

mkdir -p -- "$DEX_DIR"
unzip -p "$REBUILT_TARGET_ARCHIVE" classes.dex > "$DEX_DIR/$DEX_ENTRY" ||
	fail "回编译结果中缺少 classes.dex"
[[ -s "$DEX_DIR/$DEX_ENTRY" ]] || fail "生成的 $DEX_ENTRY 为空"

log "仅将 $DEX_ENTRY 增量写入原 APK 副本"
cp -a -- "$APK_PATH" "$PATCHED_APK"
(
	cd -- "$DEX_DIR"
	zip -q -0 "$PATCHED_APK" "$DEX_ENTRY"
)

log "重新对齐 APK"
"$ZIPALIGN_COMMAND" -f -P 16 4 "$PATCHED_APK" "$ALIGNED_APK" ||
	fail "zipalign 对齐失败"
mv -- "$ALIGNED_APK" "$PATCHED_APK"

log "回插原 APK Signing Block"
python3 "$SIGNING_BLOCK_TOOL" insert "$PATCHED_APK" "$SIGNING_BLOCK_BEFORE"
python3 "$SIGNING_BLOCK_TOOL" extract "$PATCHED_APK" "$SIGNING_BLOCK_AFTER" >/dev/null
cmp -s "$SIGNING_BLOCK_BEFORE" "$SIGNING_BLOCK_AFTER" ||
	fail "更新后 APK Signing Block 内容发生变化"
"$ZIPALIGN_COMMAND" -c -P 16 4 "$PATCHED_APK" ||
	fail "更新后的 APK 未通过 zipalign 校验"

unzip -tq "$PATCHED_APK" >/dev/null || fail "更新后的 APK 完整性校验失败"
cmp -s "$DEX_DIR/$DEX_ENTRY" <(unzip -p "$PATCHED_APK" "$DEX_ENTRY") ||
	fail "$DEX_ENTRY 未正确写入 APK"

compare_archive_contract "$APK_PATH" "$PATCHED_APK" "$DEX_ENTRY" ||
	fail "更新后 APK 的非目标归档契约发生变化"

cp --attributes-only --preserve=all -- "$APK_PATH" "$PATCHED_APK" ||
	fail "无法恢复原 MiuiSystemUI.apk 文件属性"

REPLACEMENT_PATH=$(mktemp "$APK_DIR/.MiuiSystemUI.apk.patch.XXXXXX")
rm -f -- "$REPLACEMENT_PATH"
cp -a -- "$PATCHED_APK" "$REPLACEMENT_PATH"
mv -fT -- "$REPLACEMENT_PATH" "$APK_PATH"
REPLACEMENT_PATH=''

log "APPLY：Oplus FOD 原始触摸动画触发补丁完成：$APK_PATH"
log "已保留目标 DEX 之外的全部 APK 条目、Signing Block 与 META-INF 证书材料"
log "DEX 修改后内容完整性签名与原预编译、profile 数据不再匹配"
