#!/usr/bin/env bash
set -Eeuo pipefail

readonly SETTINGS_CLASS='com/android/settings/MiuiDisplaySettings.smali'
readonly APP_FUNCTION_CLASS='com/android/settings/appfunctions/utils/MiuiAppFunctionDisplayUtils.smali'
readonly APK_DEX_ENTRY='classes2.dex'
readonly APKTOOL_DEX_ENTRY='classes.dex'
PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
readonly PATCHER_DIR
PORT_DIR=$(cd -- "$PATCHER_DIR/../../.." && pwd -P)
readonly PORT_DIR
readonly SIGNING_BLOCK_TOOL="$PORT_DIR/common/apk_signing_block.py"

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
		return
	fi
	if [[ -r /snap/apktool/current/apktool.jar ]]; then
		require_command java
		APKTOOL_COMMAND=(java -jar /snap/apktool/current/apktool.jar)
		return
	fi
	if command -v apktool >/dev/null 2>&1; then
		APKTOOL_COMMAND=(apktool)
		return
	fi
	fail '缺少 Apktool'
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
		candidate=$(find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 -type f \
			-name zipalign -perm -u+x -print | LC_ALL=C sort -V | tail -n 1)
		if [[ -n "$candidate" ]]; then
			ZIPALIGN_COMMAND=$candidate
			return
		fi
	done
	fail '缺少 zipalign'
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
    _after_name, after_method, after_data = after[index]
    if before_name == target_entry:
        if before_method != zipfile.ZIP_STORED:
            raise SystemExit(f"原目标条目不是 ZIP_STORED：{target_entry}")
        if after_method != zipfile.ZIP_STORED:
            raise SystemExit(f"目标条目未使用 ZIP_STORED：{target_entry}")
        continue
    if before_method != after_method:
        raise SystemExit(f"非目标条目压缩方式发生变化：{before_name}")
    if before_data != after_data:
        raise SystemExit(f"非目标条目内容发生变化：{before_name}")
PY
}

smali_patch_state() {
	python3 - "$1" "$2" "$3" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

target = Path(sys.argv[1])
app_function_target = Path(sys.argv[2])
mode = sys.argv[3]
if mode not in {"check", "patch"}:
    raise SystemExit("无效的 Smali 操作模式")


class PatchError(Exception):
    pass


def read(path: Path) -> str:
    try:
        return path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        raise PatchError(f"读取 Smali 失败：{path}：{error}") from error


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        raise PatchError(f"{label} 原始片段数量应为 1，实际为 {count}")
    return text.replace(old, new, 1)


def atomic_write(path: Path, text: str) -> None:
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


def remove_method(text: str, signature: str, label: str):
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


text = read(target)
app_text = read(app_function_target)
method_match = re.search(
    r"(?ms)^\.method private updatePwmValueToDF\(Z\)V\n.*?^\.end method$",
    text,
)
if method_match is None:
    raise PatchError("无法定位 MiuiDisplaySettings.updatePwmValueToDF(Z)")
method = method_match.group(0)
marker_pattern = r'const-string(?:/jumbo)? v1, "user_refresh_rate"'
marker_count = len(re.findall(marker_pattern, method))
if marker_count > 1:
    raise PatchError(f"Settings DC 切换回退门禁重复插入：{marker_count} 次")

utility_prefix = "Lcom/android/settings/appfunctions/utils/MiuiAppFunctionDisplayUtils;"
filter_call = (
    "invoke-static {v0, v4}, "
    f"{utility_prefix}->filterRefreshRateList([ILandroid/content/Context;)[I"
)
clamp_call = (
    "invoke-static {p0, p1}, "
    f"{utility_prefix}->clampRefreshRateForPwm(Landroid/content/Context;I)I"
)
filter_signature = "filterRefreshRateList([ILandroid/content/Context;)[I"
clamp_signature = "clampRefreshRateForPwm(Landroid/content/Context;I)I"

get_list_match = re.search(
    r"(?ms)^\.method public static getRefreshRateList\(Landroid/content/Context;\)Ljava/util/List;\n.*?^\.end method$",
    app_text,
)
refresh_internal_match = re.search(
    r"(?ms)^\.method private static setRefreshRateInternal\(Landroid/content/Context;I\)V\n.*?^\.end method$",
    app_text,
)
smart_fps_match = re.search(
    r"(?ms)^\.method private static setSmartFps\(Landroid/content/Context;I\)V\n.*?^\.end method$",
    app_text,
)
if get_list_match is None or refresh_internal_match is None or smart_fps_match is None:
    raise PatchError("无法定位 Settings AppFunction 刷新率方法")
get_list_method = get_list_match.group(0)
refresh_internal_method = refresh_internal_match.group(0)
smart_fps_method = smart_fps_match.group(0)

original_threshold = "const/16 v0, 0x3c\n\n    if-eq p1, v0, :cond_0"
patched_threshold = "const/16 v0, 0x90\n\n    if-lt p1, v0, :cond_0"
threshold_patched_state = (
    refresh_internal_method.count(patched_threshold) == 1
    and smart_fps_method.count(patched_threshold) == 1
)
threshold_original_state = (
    refresh_internal_method.count(original_threshold) == 1
    and smart_fps_method.count(original_threshold) == 1
)
if not threshold_patched_state and not threshold_original_state:
    raise PatchError("无法识别 Settings AppFunction DC/高刷互斥阈值状态")

def method_count(text_value: str, signature: str) -> int:
    return len(re.findall(rf"(?m)^\.method [^\n]*{re.escape(signature)}\n", text_value))


filter_call_pattern = re.compile(
    rf"(?m)^[ \t]*{re.escape(filter_call)}\n(?:\n[ \t]*)*^[ \t]*move-result-object v0[ \t]*\n?"
)
clamp_call_pattern = re.compile(
    rf"(?m)^[ \t]*{re.escape(clamp_call)}\n(?:\n[ \t]*)*^[ \t]*move-result p1[ \t]*\n?"
)
filter_call_count = len(filter_call_pattern.findall(get_list_method))
clamp_call_count = len(clamp_call_pattern.findall(refresh_internal_method))
if filter_call_count > 1 or clamp_call_count > 1:
    raise PatchError(
        "Settings AppFunction Pro 门禁调用数量异常："
        f"列表 {filter_call_count} 次，写入 {clamp_call_count} 次"
    )
filter_method_count = method_count(app_text, filter_signature)
clamp_method_count = method_count(app_text, clamp_signature)
if filter_method_count > 1 or clamp_method_count > 1:
    raise PatchError(
        "Settings AppFunction Pro 门禁方法数量异常："
        f"列表 {filter_method_count} 个，写入 {clamp_method_count} 个"
    )
update_gate_present = marker_count == 1
if update_gate_present and "const/16 v3, 0x78" not in method:
    raise PatchError("Settings DC 切换回退门禁存在但结构不完整")

final_state = (
    threshold_patched_state
    and not update_gate_present
    and filter_call_count == 0
    and clamp_call_count == 0
    and filter_method_count == 0
    and clamp_method_count == 0
)
original_state = (
    threshold_original_state
    and not update_gate_present
    and filter_call_count == 0
    and clamp_call_count == 0
    and filter_method_count == 0
    and clamp_method_count == 0
)
if mode == "check":
    print("patched" if final_state else "original" if original_state else "partial")
    raise SystemExit(0)

changed = 0
if update_gate_present:
    update_gate_pattern = re.compile(
        r"(?ms)^\.method private updatePwmValueToDF\(Z\)V\n.*?"
        r"(?P<anchor>^[ \t]*sget-object p0, Lcom/android/settings/MiuiDisplaySettings;->TAG:Ljava/lang/String;\n)"
    )
    updated_method, removed_gate = update_gate_pattern.subn(
        lambda match: (
            ".method private updatePwmValueToDF(Z)V\n"
            "    .locals 2\n\n"
            "    .line 986\n"
            + match.group("anchor")
        ),
        method,
        count=1,
    )
    if removed_gate != 1:
        raise PatchError("Settings DC 切换回退门禁移除失败")
    text = text.replace(method, updated_method, 1)
    changed += 1

app_changed = False
updated_app = app_text
updated_get_list = get_list_method
updated_refresh_internal = refresh_internal_method
updated_smart_fps = smart_fps_method
if threshold_original_state:
    updated_refresh_internal = replace_once(
        updated_refresh_internal, original_threshold, patched_threshold,
        "Settings AppFunction DC 互斥阈值",
    )
    updated_smart_fps = replace_once(
        updated_smart_fps, original_threshold, patched_threshold,
        "Settings AppFunction 自适应刷新率互斥阈值",
    )
    app_changed = True

if filter_call_count == 1:
    updated_get_list, removed_filter = filter_call_pattern.subn("", updated_get_list, count=1)
    if removed_filter != 1:
        raise PatchError("Settings AppFunction 刷新率列表门禁移除失败")
    app_changed = True
if "    move-object v4, p0\n" in updated_get_list:
    updated_get_list = updated_get_list.replace("    move-object v4, p0\n", "", 1)
    app_changed = True
if clamp_call_count == 1:
    updated_refresh_internal, removed_clamp = clamp_call_pattern.subn("", updated_refresh_internal, count=1)
    if removed_clamp != 1:
        raise PatchError("Settings AppFunction 刷新率写入门禁移除失败")
    app_changed = True

if filter_method_count == 1:
    updated_app, removed_filter_method = remove_method(
        updated_app, "filterRefreshRateList([ILandroid/content/Context;)[I", "Settings AppFunction 列表门禁方法"
    )
    if not removed_filter_method:
        raise PatchError("Settings AppFunction 列表门禁方法移除失败")
    app_changed = True
if clamp_method_count == 1:
    updated_app, removed_clamp_method = remove_method(
        updated_app, "clampRefreshRateForPwm(Landroid/content/Context;I)I", "Settings AppFunction 写入门禁方法"
    )
    if not removed_clamp_method:
        raise PatchError("Settings AppFunction 写入门禁方法移除失败")
    app_changed = True

if app_changed:
    updated_app = replace_once(updated_app, get_list_method, updated_get_list, "Settings AppFunction 刷新率列表门禁")
    updated_app = replace_once(updated_app, refresh_internal_method, updated_refresh_internal, "Settings AppFunction 刷新率写入门禁")
    updated_app = replace_once(updated_app, smart_fps_method, updated_smart_fps, "Settings AppFunction 自适应刷新率互斥阈值")
    atomic_write(app_function_target, updated_app)
    changed += 1

if changed == 0:
    raise PatchError("Settings DEX 没有可应用的修改")
if text != read(target):
    atomic_write(target, text)
print(f"patched {changed}")
PY
}

(( $# == 1 )) || fail "用法：$0 <Settings.apk>"
APK_PATH=$1

for command_name in awk cmp cp find java mktemp mv python3 rm sort tail unzip zip; do
	require_command "$command_name"
done
resolve_apktool
resolve_zipalign
[[ -r "$SIGNING_BLOCK_TOOL" ]] || fail "找不到 Signing Block 工具：$SIGNING_BLOCK_TOOL"
[[ -f "$APK_PATH" && ! -L "$APK_PATH" ]] || fail "Settings.apk 不存在或是符号链接：$APK_PATH"
APK_PATH="$(cd -- "$(dirname -- "$APK_PATH")" && pwd -P)/$(basename -- "$APK_PATH")"
APK_DIR=$(dirname -- "$APK_PATH")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/op15-settings-dc-refresh.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR="$WORK_DIR/decoded"
TARGET_ARCHIVE_DIR="$WORK_DIR/target"
TARGET_ARCHIVE="$WORK_DIR/target.apk"
REBUILT_TARGET_ARCHIVE="$WORK_DIR/target-rebuilt.apk"
DEX_DIR="$WORK_DIR/dex"
PATCHED_APK="$WORK_DIR/Settings.apk.patched"
ALIGNED_APK="$WORK_DIR/Settings.apk.aligned"
SIGNING_BLOCK_BEFORE="$WORK_DIR/signing-block.before"
SIGNING_BLOCK_AFTER="$WORK_DIR/signing-block.after"

python3 - "$APK_PATH" "$APK_DEX_ENTRY" <<'PY'
import sys
import zipfile

apk_path, target_entry = sys.argv[1:]
try:
    with zipfile.ZipFile(apk_path) as archive:
        names = [info.filename for info in archive.infolist()]
        if names.count(target_entry) != 1:
            raise SystemExit(f"Settings.apk 中 {target_entry} 数量不是 1")
except (OSError, RuntimeError, ValueError, zipfile.BadZipFile) as error:
    raise SystemExit(f"无法读取 Settings.apk ZIP：{error}") from error
PY
python3 "$SIGNING_BLOCK_TOOL" extract "$APK_PATH" "$SIGNING_BLOCK_BEFORE" >/dev/null

mkdir -p -- "$TARGET_ARCHIVE_DIR"
unzip -p "$APK_PATH" "$APK_DEX_ENTRY" > "$TARGET_ARCHIVE_DIR/$APKTOOL_DEX_ENTRY" || fail "提取 $APK_DEX_ENTRY 失败"
[[ -s "$TARGET_ARCHIVE_DIR/$APKTOOL_DEX_ENTRY" ]] || fail "$APK_DEX_ENTRY 为空"
(
	cd -- "$TARGET_ARCHIVE_DIR"
	zip -q -0 "$TARGET_ARCHIVE" "$APKTOOL_DEX_ENTRY"
)

log '反编译 Settings.apk 的显示调光链路'
"${APKTOOL_COMMAND[@]}" d -j 1 -f -r -o "$DECODE_DIR" "$TARGET_ARCHIVE"
target_smali_path="$DECODE_DIR/smali/$SETTINGS_CLASS"
if [[ ! -f "$target_smali_path" ]]; then
	target_smali_path="$DECODE_DIR/smali_classes2/$SETTINGS_CLASS"
fi
[[ -f "$target_smali_path" ]] || fail "目标 Smali 不存在：$SETTINGS_CLASS"
app_function_smali_path="$DECODE_DIR/smali/$APP_FUNCTION_CLASS"
if [[ ! -f "$app_function_smali_path" ]]; then
	app_function_smali_path="$DECODE_DIR/smali_classes2/$APP_FUNCTION_CLASS"
fi
[[ -f "$app_function_smali_path" ]] || fail "目标 Smali 不存在：$APP_FUNCTION_CLASS"

read -r PATCH_STATE < <(smali_patch_state "$target_smali_path" "$app_function_smali_path" check)
case "$PATCH_STATE" in
	patched)
		unzip -tq "$APK_PATH" >/dev/null || fail '已补丁 Settings.apk 完整性校验失败'
		"$ZIPALIGN_COMMAND" -c -P 16 4 "$APK_PATH" >/dev/null
		log 'SKIP：Settings/AppFunction 已移除 Pro 状态高刷列表与写入回退'
		exit 0
		;;
	original|partial) ;;
	*) fail "无法识别 Settings Smali 状态：$PATCH_STATE" ;;
esac

read -r PATCH_STATE CHANGED_COUNT < <(
	smali_patch_state "$target_smali_path" "$app_function_smali_path" patch
)
[[ "$PATCH_STATE" == patched && "$CHANGED_COUNT" =~ ^[1-2]$ ]] ||
	fail "Settings Smali 修改结果异常：state=$PATCH_STATE changed=$CHANGED_COUNT"

"${APKTOOL_COMMAND[@]}" b -j 1 "$DECODE_DIR" -o "$REBUILT_TARGET_ARCHIVE"
mkdir -p -- "$DEX_DIR"
unzip -p "$REBUILT_TARGET_ARCHIVE" "$APKTOOL_DEX_ENTRY" > "$DEX_DIR/$APK_DEX_ENTRY" || fail "回编译结果没有 $APKTOOL_DEX_ENTRY"
[[ -s "$DEX_DIR/$APK_DEX_ENTRY" ]] || fail "回编译的 $APK_DEX_ENTRY 为空"

cp -a -- "$APK_PATH" "$PATCHED_APK"
(
	cd -- "$DEX_DIR"
	zip -q -0 "$PATCHED_APK" "$APK_DEX_ENTRY"
)
"$ZIPALIGN_COMMAND" -f -P 16 4 "$PATCHED_APK" "$ALIGNED_APK" || fail 'zipalign 失败'
mv -- "$ALIGNED_APK" "$PATCHED_APK"
python3 "$SIGNING_BLOCK_TOOL" insert "$PATCHED_APK" "$SIGNING_BLOCK_BEFORE"
python3 "$SIGNING_BLOCK_TOOL" extract "$PATCHED_APK" "$SIGNING_BLOCK_AFTER" >/dev/null
cmp -s "$SIGNING_BLOCK_BEFORE" "$SIGNING_BLOCK_AFTER" || fail 'APK Signing Block 发生变化'
"$ZIPALIGN_COMMAND" -c -P 16 4 "$PATCHED_APK" || fail '更新后的 APK 未通过 zipalign'
unzip -tq "$PATCHED_APK" >/dev/null || fail '更新后的 APK 完整性校验失败'
cmp -s "$DEX_DIR/$APK_DEX_ENTRY" <(unzip -p "$PATCHED_APK" "$APK_DEX_ENTRY") || fail "$APK_DEX_ENTRY 未写回 APK"
archive_contract_check "$APK_PATH" "$PATCHED_APK" "$APK_DEX_ENTRY" || fail 'APK 条目名称、顺序、压缩方式或非目标内容发生变化'

cp --attributes-only --preserve=all -- "$APK_PATH" "$PATCHED_APK" || fail '无法恢复 APK 属性'
REPLACEMENT_PATH=$(mktemp "$APK_DIR/.Settings.apk.patch.XXXXXX")
rm -f -- "$REPLACEMENT_PATH"
cp -a -- "$PATCHED_APK" "$REPLACEMENT_PATH"
mv -fT -- "$REPLACEMENT_PATH" "$APK_PATH"
REPLACEMENT_PATH=''

log "APPLY：Settings/AppFunction 已保留完整刷新率列表，Pro 仅请求全局 PWM：$APK_PATH"
