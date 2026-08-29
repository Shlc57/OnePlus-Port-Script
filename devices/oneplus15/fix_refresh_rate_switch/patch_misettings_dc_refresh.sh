#!/usr/bin/env bash
set -Eeuo pipefail

readonly NEW_REFRESH_CLASS='com/xiaomi/misettings/display/RefreshRate/NewRefreshRateFragment.smali'
# shellcheck disable=SC2016
readonly ANTI_FLICKER_CLASS='com/xiaomi/misettings/display/AntiFlickerMode/AntiFlickerActivity$ChooseModeFragment.smali'
readonly ANTI_FLICKER_CONFIRM_CLASS='com/xiaomi/misettings/display/AntiFlickerMode/d.smali'
readonly REFRESH_WRITE_UTIL_CLASS='wa/a.smali'
PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly PATCHER_DIR
PORT_DIR=$(cd -- "$PATCHER_DIR/../../.." && pwd -P)
readonly PORT_DIR
readonly SIGNING_BLOCK_TOOL="$PORT_DIR/tools/apk_signing_block.py"
# shellcheck source=../../../tools/toolchain.sh
# shellcheck disable=SC1091 # 仓库根目录由补丁目录运行时定位。
source "$PORT_DIR/tools/toolchain.sh"

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
	toolchain_resolve_apktool || fail '无法解析 Apktool'
	APKTOOL_COMMAND=("${PORT_TOOL_APKTOOL_COMMAND[@]}")
}

resolve_zipalign() {
	toolchain_resolve_zipalign || fail '无法解析 zipalign'
	ZIPALIGN_COMMAND="$PORT_TOOL_ZIPALIGN"
}

archive_contract_check() {
	python3 - "$1" "$2" "$3" <<'PY'
import sys
import zipfile

before_path, after_path, target_entry = sys.argv[1:]


def read_archive(path):
    with zipfile.ZipFile(path, "r") as archive:
        infos = archive.infolist()
        names = [info.filename for info in infos]
        if len(names) != len(set(names)):
            raise SystemExit(f"ZIP 包含重复条目：{path}")
        return [
            (info.filename, info.compress_type, archive.read(info))
            for info in infos
        ]


try:
    before = read_archive(before_path)
    after = read_archive(after_path)
except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
    raise SystemExit(f"无法读取 APK ZIP：{error}") from error

before_names = [item[0] for item in before]
after_names = [item[0] for item in after]
if before_names != after_names:
    raise SystemExit("APK 归档条目名称或顺序发生变化")
if before_names.count(target_entry) != 1:
    raise SystemExit(f"目标条目数量不是 1：{target_entry}")

for index, (before_name, before_method, before_data) in enumerate(before):
    after_name, after_method, after_data = after[index]
    if before_name == target_entry:
        if before_method != after_method:
            raise SystemExit(
                f"目标条目压缩方式发生变化：{target_entry}："
                f"{before_method} -> {after_method}"
            )
        continue
    if before_method != after_method:
        raise SystemExit(f"非目标条目压缩方式发生变化：{before_name}")
    if before_data != after_data:
        raise SystemExit(f"非目标条目内容发生变化：{before_name}")
PY
}

smali_patch_state() {
	python3 - "$1" "$2" "$3" "$4" "$5" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

new_refresh = Path(sys.argv[1])
anti_flicker = Path(sys.argv[2])
confirm = Path(sys.argv[3])
refresh_write_util = Path(sys.argv[4])
mode = sys.argv[5]
if mode not in {"check", "patch"}:
    raise SystemExit("无效的 Smali 操作模式")


class PatchError(Exception):
    pass


def read(path):
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise PatchError(f"读取 Smali 失败：{path}：{error}") from error


def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise PatchError(f"{label} 原始片段数量应为 1，实际为 {count}")
    return text.replace(old, new, 1)


def atomic_write(path, text):
    file_mode = stat.S_IMODE(path.stat().st_mode)
    temporary_name = None
    try:
        with tempfile.NamedTemporaryFile(
            mode="w", encoding="utf-8", newline="", prefix=f".{path.name}.",
            suffix=".tmp", dir=path.parent, delete=False
        ) as temporary:
            temporary_name = temporary.name
            temporary.write(text)
            temporary.flush()
            os.fsync(temporary.fileno())
        os.chmod(temporary_name, file_mode)
        os.replace(temporary_name, path)
    except OSError:
        if temporary_name:
            try:
                os.unlink(temporary_name)
            except OSError:
                pass
        raise


gate_invoke = "invoke-static {p2}, Lcom/xiaomi/misettings/display/RefreshRate/NewRefreshRateFragment;->D([I)[I"
gate_method_signature = "D([I)[I"


def remove_method(text, signature, label):
    pattern = re.compile(
        rf"(?ms)^\.method [^\n]*{re.escape(signature)}\n.*?^\.end method\n?"
    )
    matches = list(pattern.finditer(text))
    if len(matches) > 1:
        raise PatchError(f"{label} 数量应为 0 或 1，实际为 {len(matches)}")
    if not matches:
        return text, False
    match = matches[0]
    return text[: match.start()] + text[match.end() :], True

new_text = read(new_refresh)
anti_text = read(anti_flicker)
confirm_text = read(confirm)
util_text = read(refresh_write_util)

original_new = [
    ("const/16 v0, 0x3c\n\n    .line 6\n    .line 7\n    if-eq p0, v0, :cond_0",
     "const/16 v0, 0x90\n\n    .line 6\n    .line 7\n    if-lt p0, v0, :cond_0", "刷新率静态切换"),
    ("const/16 v0, 0x3c\n\n    .line 6\n    .line 7\n    if-eq p1, v0, :cond_0",
     "const/16 v0, 0x90\n\n    .line 6\n    .line 7\n    if-lt p1, v0, :cond_0", "刷新率动态切换"),
]
original_anti = (
    "const/16 v3, 0x3c\n\n    .line 58\n    .line 59\n    if-eq p1, v3, :cond_2",
    "const/16 v3, 0x90\n\n    .line 58\n    .line 59\n    if-lt p1, v3, :cond_2",
)
original_confirm = (
    "const/16 v0, 0x3c\n\n    .line 12\n    .line 13\n    if-eq p2, v0, :cond_0",
    "const/16 v0, 0x90\n\n    .line 12\n    .line 13\n    if-lt p2, v0, :cond_0",
)
original_confirm_target = (
    "move-result-object p2\n\n    .line 19\n    invoke-static {p2, v0}, Lwa/a;->m(Landroid/content/Context;I)V",
    "move-result-object p2\n\n    .line 19\n    const/16 v0, 0x78\n\n    invoke-static {p2, v0}, Lwa/a;->m(Landroid/content/Context;I)V",
)

threshold_patched = all(new in new_text for _, new, _ in original_new)
threshold_patched = threshold_patched and original_anti[1] in anti_text
threshold_patched = threshold_patched and original_confirm[1] in confirm_text
threshold_patched = threshold_patched and original_confirm_target[1] in confirm_text
threshold_original = all(old in new_text for old, _, _ in original_new)
threshold_original = threshold_original and original_anti[0] in anti_text
threshold_original = threshold_original and original_confirm[0] in confirm_text
threshold_original = threshold_original and original_confirm_target[0] in confirm_text
util_method_match = re.search(
    r"(?ms)^\.method public static m\(Landroid/content/Context;I\)V\n.*?^\.end method$",
    util_text,
)
if util_method_match is None:
    raise PatchError("无法定位刷新率公共写入方法 wa/a.m")
util_method = util_method_match.group(0)
util_marker = 'const-string v1, "mimotion_pwm_enable"'
util_marker_count = util_method.count(util_marker)
if util_marker_count > 1:
    raise PatchError(f"刷新率公共写入门禁重复插入：{util_marker_count} 次")
gate_invoke_count = new_text.count(gate_invoke)
gate_method_count = len(
    re.findall(rf"(?m)^\.method [^\n]*{re.escape(gate_method_signature)}$", new_text)
)
if gate_invoke_count > 1 or gate_method_count > 1:
    raise PatchError(
        "Pro 高刷新率列表门禁残留数量异常："
        f"调用 {gate_invoke_count} 次，方法 {gate_method_count} 次"
    )
if not threshold_patched and not threshold_original:
    raise PatchError("无法识别 MISettings DC/高刷互斥阈值状态")
util_gate_present = util_marker_count == 1
if util_gate_present and "const/16 p1, 0x78" not in util_method:
    raise PatchError("刷新率公共写入门禁存在但结构不完整")
final_state = threshold_patched and gate_invoke_count == 0 and gate_method_count == 0 and not util_gate_present
original_state = threshold_original and gate_invoke_count == 0 and gate_method_count == 0 and not util_gate_present
if mode == "check":
    print("patched" if final_state else "original" if original_state else "partial")
    raise SystemExit(0)
if final_state:
    print("patched 0")
    raise SystemExit(0)

changed = 0
if threshold_original:
    for old, new, label in original_new:
        new_text = replace_once(new_text, old, new, label)
    anti_text = replace_once(anti_text, original_anti[0], original_anti[1], "DC 开启确认")
    confirm_text = replace_once(confirm_text, original_confirm[0], original_confirm[1], "DC 确认阈值")
    confirm_text = replace_once(confirm_text, original_confirm_target[0], original_confirm_target[1], "DC 回退刷新率")
    changed += 4
if gate_invoke_count == 1:
    gate_call_pattern = re.compile(
        rf"(?m)^[ \t]*{re.escape(gate_invoke)}\n(?:\n[ \t]*)*^[ \t]*move-result-object p2[ \t]*\n?"
    )
    new_text, removed_calls = gate_call_pattern.subn("", new_text)
    if removed_calls != 1:
        raise PatchError(f"Pro 高刷新率列表调用移除数量应为 1，实际为 {removed_calls}")
    changed += 1
if gate_method_count == 1:
    new_text, removed_method = remove_method(new_text, gate_method_signature, "Pro 高刷新率列表方法")
    if not removed_method:
        raise PatchError("Pro 高刷新率列表方法移除失败")
    changed += 1

if util_gate_present:
    gate_pattern = re.compile(
        r"(?ms)(?P<label>^[ \t]*:cond_\d+\n)"
        r"[ \t]*invoke-virtual \{p0\}, Landroid/content/Context;->getContentResolver\(\)Landroid/content/ContentResolver;\n"
        r".*?"
        r"^[ \t]*(?::goto_\d+|:cond_\d+)\n"
        r"(?P<sget>[ \t]*sget v0, Landroid/os/Build\$VERSION;->SDK_INT:I[^\n]*\n)"
    )
    updated_util_method, removed_gate = gate_pattern.subn(
        lambda match: match.group("label") + match.group("sget"), util_method, count=1
    )
    if removed_gate != 1:
        raise PatchError("刷新率公共写入门禁移除失败")
    util_text = util_text.replace(util_method, updated_util_method, 1)
    changed += 1

atomic_write(new_refresh, new_text)
atomic_write(anti_flicker, anti_text)
atomic_write(confirm, confirm_text)
atomic_write(refresh_write_util, util_text)
print(f"patched {changed}")
PY
}

(( $# == 1 )) || fail "用法：$0 <MISettings.apk>"
APK_PATH=$1

for command_name in awk cmp cp find java mktemp mv python3 rm sort tail unzip zip; do
	require_command "$command_name"
done
resolve_apktool
resolve_zipalign
[[ -r "$SIGNING_BLOCK_TOOL" ]] || fail "找不到 Signing Block 工具：$SIGNING_BLOCK_TOOL"
[[ -f "$APK_PATH" && ! -L "$APK_PATH" ]] || fail "MISettings.apk 不存在或是符号链接：$APK_PATH"
APK_PATH="$(cd -- "$(dirname -- "$APK_PATH")" && pwd -P)/$(basename -- "$APK_PATH")"
APK_DIR=$(dirname -- "$APK_PATH")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/op15-misettings-dc-refresh.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR="$WORK_DIR/decoded"
TARGET_ARCHIVE_DIR="$WORK_DIR/target"
TARGET_ARCHIVE="$WORK_DIR/target.apk"
REBUILT_TARGET_ARCHIVE="$WORK_DIR/target-rebuilt.apk"
DEX_DIR="$WORK_DIR/dex"
PATCHED_APK="$WORK_DIR/MISettings.apk.patched"
ALIGNED_APK="$WORK_DIR/MISettings.apk.aligned"
SIGNING_BLOCK_BEFORE="$WORK_DIR/signing-block.before"
SIGNING_BLOCK_AFTER="$WORK_DIR/signing-block.after"
readonly DEX_ENTRY='classes.dex'
TARGET_ZIP_OPTIONS=()

python3 - "$APK_PATH" "$DEX_ENTRY" <<'PY'
import sys
import zipfile

apk_path, target_entry = sys.argv[1:]
try:
    with zipfile.ZipFile(apk_path) as archive:
        names = [info.filename for info in archive.infolist()]
        if names.count(target_entry) != 1:
            raise SystemExit(f"MISettings.apk 中 {target_entry} 数量不是 1")
except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
    raise SystemExit(f"无法读取 MISettings.apk ZIP：{error}") from error
PY
TARGET_COMPRESS_TYPE=$(python3 - "$APK_PATH" "$DEX_ENTRY" <<'PY'
import sys
import zipfile

apk_path, target_entry = sys.argv[1:]
with zipfile.ZipFile(apk_path) as archive:
    compress_type = archive.getinfo(target_entry).compress_type
if compress_type not in (zipfile.ZIP_STORED, zipfile.ZIP_DEFLATED):
    raise SystemExit(
        f"不支持 {target_entry} 的 ZIP 压缩方式：{compress_type}，"
        "仅支持 ZIP_STORED 或 ZIP_DEFLATED"
    )
print(compress_type)
PY
)
if [[ "$TARGET_COMPRESS_TYPE" == 0 ]]; then
	TARGET_ZIP_OPTIONS=(-0)
fi
python3 "$SIGNING_BLOCK_TOOL" extract "$APK_PATH" "$SIGNING_BLOCK_BEFORE" >/dev/null

mkdir -p -- "$TARGET_ARCHIVE_DIR"
unzip -p "$APK_PATH" "$DEX_ENTRY" > "$TARGET_ARCHIVE_DIR/classes.dex" || fail "提取 $DEX_ENTRY 失败"
[[ -s "$TARGET_ARCHIVE_DIR/classes.dex" ]] || fail "$DEX_ENTRY 为空"
(
	cd -- "$TARGET_ARCHIVE_DIR"
	zip -q -0 "$TARGET_ARCHIVE" classes.dex
)

log '反编译 MISettings 的 classes.dex'
"${APKTOOL_COMMAND[@]}" d -j 1 -f -r -o "$DECODE_DIR" "$TARGET_ARCHIVE"
for class_path in "$NEW_REFRESH_CLASS" "$ANTI_FLICKER_CLASS" "$ANTI_FLICKER_CONFIRM_CLASS"; do
	[[ -f "$DECODE_DIR/smali/$class_path" ]] || fail "目标 Smali 不存在：$class_path"
done
[[ -f "$DECODE_DIR/smali/$REFRESH_WRITE_UTIL_CLASS" ]] || fail "目标 Smali 不存在：$REFRESH_WRITE_UTIL_CLASS"

read -r PATCH_STATE < <(smali_patch_state \
	"$DECODE_DIR/smali/$NEW_REFRESH_CLASS" \
	"$DECODE_DIR/smali/$ANTI_FLICKER_CLASS" \
	"$DECODE_DIR/smali/$ANTI_FLICKER_CONFIRM_CLASS" \
	"$DECODE_DIR/smali/$REFRESH_WRITE_UTIL_CLASS" check)
case "$PATCH_STATE" in
	patched)
		unzip -tq "$APK_PATH" >/dev/null || fail '已补丁 APK 完整性校验失败'
		"$ZIPALIGN_COMMAND" -c -P 16 4 "$APK_PATH" >/dev/null
		log 'SKIP：MISettings 已保留完整刷新率列表，并移除 Pro 状态高刷过滤'
		exit 0
		;;
	original|partial) ;;
	*) fail "无法识别 MISettings Smali 状态：$PATCH_STATE" ;;
esac

log '将 DC/高刷互斥阈值由 60Hz 收窄至 144Hz，并移除 Pro 状态高刷过滤与公共写入回退'
read -r PATCH_STATE CHANGED_COUNT < <(smali_patch_state \
	"$DECODE_DIR/smali/$NEW_REFRESH_CLASS" \
	"$DECODE_DIR/smali/$ANTI_FLICKER_CLASS" \
	"$DECODE_DIR/smali/$ANTI_FLICKER_CONFIRM_CLASS" \
	"$DECODE_DIR/smali/$REFRESH_WRITE_UTIL_CLASS" patch)
[[ "$PATCH_STATE" == patched && "$CHANGED_COUNT" =~ ^[1-6]$ ]] ||
	fail "Smali 修改结果异常：state=$PATCH_STATE changed=$CHANGED_COUNT"

"${APKTOOL_COMMAND[@]}" b -j 1 "$DECODE_DIR" -o "$REBUILT_TARGET_ARCHIVE"
mkdir -p -- "$DEX_DIR"
unzip -p "$REBUILT_TARGET_ARCHIVE" classes.dex > "$DEX_DIR/$DEX_ENTRY" || fail "回编译结果没有 $DEX_ENTRY"
[[ -s "$DEX_DIR/$DEX_ENTRY" ]] || fail "回编译的 $DEX_ENTRY 为空"

cp -a -- "$APK_PATH" "$PATCHED_APK"
(
	cd -- "$DEX_DIR"
	zip -q "${TARGET_ZIP_OPTIONS[@]}" "$PATCHED_APK" "$DEX_ENTRY"
)
"$ZIPALIGN_COMMAND" -f -P 16 4 "$PATCHED_APK" "$ALIGNED_APK" || fail 'zipalign 失败'
mv -- "$ALIGNED_APK" "$PATCHED_APK"
python3 "$SIGNING_BLOCK_TOOL" insert "$PATCHED_APK" "$SIGNING_BLOCK_BEFORE"
python3 "$SIGNING_BLOCK_TOOL" extract "$PATCHED_APK" "$SIGNING_BLOCK_AFTER" >/dev/null
cmp -s "$SIGNING_BLOCK_BEFORE" "$SIGNING_BLOCK_AFTER" || fail 'APK Signing Block 发生变化'
"$ZIPALIGN_COMMAND" -c -P 16 4 "$PATCHED_APK" || fail '更新后的 APK 未通过 zipalign'
unzip -tq "$PATCHED_APK" >/dev/null || fail '更新后的 APK 完整性校验失败'
cmp -s "$DEX_DIR/$DEX_ENTRY" <(unzip -p "$PATCHED_APK" "$DEX_ENTRY") || fail "$DEX_ENTRY 未写回 APK"
archive_contract_check "$APK_PATH" "$PATCHED_APK" "$DEX_ENTRY" || fail 'APK 条目名称、顺序、压缩方式或非目标内容发生变化'

cp --attributes-only --preserve=all -- "$APK_PATH" "$PATCHED_APK" || fail '无法恢复 APK 属性'
REPLACEMENT_PATH=$(mktemp "$APK_DIR/.MISettings.apk.patch.XXXXXX")
rm -f -- "$REPLACEMENT_PATH"
cp -a -- "$PATCHED_APK" "$REPLACEMENT_PATH"
mv -fT -- "$REPLACEMENT_PATH" "$APK_PATH"
REPLACEMENT_PATH=''

log "APPLY：已保留完整刷新率列表，Pro 仅负责全局 PWM 请求：$APK_PATH"
