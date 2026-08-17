#!/usr/bin/env bash
set -Eeuo pipefail

CLASS_PATH='com/miui/keyguard/biometrics/fod/MiuiGxzwIconView.smali'
PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PORT_ROOT=$(cd -- "$PATCHER_DIR/../.." && pwd -P)
SIGNING_BLOCK_TOOL="$PORT_ROOT/common/fix_settings_haptic/apk_signing_block.py"

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

archive_entries_snapshot() {
	local apk_file=$1
	local output_file=$2

	LC_ALL=C unzip -Z1 "$apk_file" | LC_ALL=C sort > "$output_file"
}

archive_content_snapshot() {
	local apk_file=$1
	local excluded_entry=$2
	local output_file=$3

	python3 - "$apk_file" "$excluded_entry" "$output_file" <<'PY'
import hashlib
import json
import sys
import zipfile


apk_path, excluded_entry, output_path = sys.argv[1:]

with zipfile.ZipFile(apk_path) as archive, open(
    output_path, "w", encoding="utf-8", newline="\n"
) as output:
    for index, info in enumerate(archive.infolist()):
        if info.filename == excluded_entry:
            continue
        digest = hashlib.sha256()
        with archive.open(info) as entry:
            for chunk in iter(lambda: entry.read(1024 * 1024), b""):
                digest.update(chunk)
        output.write(
            "{}\t{}\t{}\t{}\t{}\t{}\n".format(
                index,
                json.dumps(info.filename, ensure_ascii=True),
                info.compress_type,
                info.file_size,
                info.CRC,
                digest.hexdigest(),
            )
        )
PY
}

signature_snapshot() {
	local apk_file=$1
	local output_file=$2
	local entries_file=$3
	local entry digest

	LC_ALL=C unzip -Z1 "$apk_file" |
		awk 'toupper($0) ~ /^META-INF\/.*\.(MF|SF|RSA|DSA|EC)$/ { print }' |
		LC_ALL=C sort > "$entries_file"

	: > "$output_file"
	while IFS= read -r entry; do
		[[ -n "$entry" ]] || continue
		digest=$(unzip -p "$apk_file" "$entry" | sha256sum | awk '{ print $1 }')
		printf '%s\t%s\n' "$digest" "$entry" >> "$output_file"
	done < "$entries_file"
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

for command_name in awk basename cmp cp dirname find mkdir mktemp mv python3 rm sha256sum sort tail unzip zip; do
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
ARCHIVE_ENTRIES_BEFORE="$WORK_DIR/archive-entries.before"
ARCHIVE_ENTRIES_AFTER="$WORK_DIR/archive-entries.after"
NON_TARGET_CONTENT_BEFORE="$WORK_DIR/non-target-content.before"
NON_TARGET_CONTENT_AFTER="$WORK_DIR/non-target-content.after"
SIGNATURES_BEFORE="$WORK_DIR/signatures.before"
SIGNATURES_AFTER="$WORK_DIR/signatures.after"
SIGNATURE_ENTRIES_BEFORE="$WORK_DIR/signature-entries.before"
SIGNATURE_ENTRIES_AFTER="$WORK_DIR/signature-entries.after"
SIGNING_BLOCK_BEFORE="$WORK_DIR/apk-signing-block.before"
SIGNING_BLOCK_AFTER="$WORK_DIR/apk-signing-block.after"

log "记录原 MiuiSystemUI.apk 的归档条目和签名数据"
archive_entries_snapshot "$APK_PATH" "$ARCHIVE_ENTRIES_BEFORE"
signature_snapshot "$APK_PATH" "$SIGNATURES_BEFORE" "$SIGNATURE_ENTRIES_BEFORE"
SIGNING_BLOCK_PAIR_IDS=$(
	python3 "$SIGNING_BLOCK_TOOL" extract "$APK_PATH" "$SIGNING_BLOCK_BEFORE"
)
log "已保存原 APK Signing Block Pair IDs：$SIGNING_BLOCK_PAIR_IDS"

DEX_ENTRY=$(find_target_dex_entry "$APK_PATH")
DEX_ENTRY_COUNT=$(awk -v entry="$DEX_ENTRY" '$0 == entry { count++ } END { print count + 0 }' "$ARCHIVE_ENTRIES_BEFORE")
(( DEX_ENTRY_COUNT == 1 )) ||
	fail "原 APK 中 $DEX_ENTRY 数量异常：期望 1 个，实际 $DEX_ENTRY_COUNT 个"
archive_content_snapshot "$APK_PATH" "$DEX_ENTRY" "$NON_TARGET_CONTENT_BEFORE"

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

archive_entries_snapshot "$PATCHED_APK" "$ARCHIVE_ENTRIES_AFTER"
cmp -s "$ARCHIVE_ENTRIES_BEFORE" "$ARCHIVE_ENTRIES_AFTER" ||
	fail "更新后 APK 的归档条目列表发生变化"
archive_content_snapshot "$PATCHED_APK" "$DEX_ENTRY" "$NON_TARGET_CONTENT_AFTER"
cmp -s "$NON_TARGET_CONTENT_BEFORE" "$NON_TARGET_CONTENT_AFTER" ||
	fail "更新后存在目标 DEX 之外的条目内容变化"

signature_snapshot "$PATCHED_APK" "$SIGNATURES_AFTER" "$SIGNATURE_ENTRIES_AFTER"
cmp -s "$SIGNATURE_ENTRIES_BEFORE" "$SIGNATURE_ENTRIES_AFTER" ||
	fail "更新后签名条目列表发生变化"
cmp -s "$SIGNATURES_BEFORE" "$SIGNATURES_AFTER" ||
	fail "更新后签名条目内容发生变化"

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
