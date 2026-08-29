#!/usr/bin/env bash
set -Eeuo pipefail

PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PORT_DIR=$(cd -- "$PATCHER_DIR/../.." && pwd -P)
APK_PATCHER="$PORT_DIR/tools/apk_patcher.sh"

log() { printf '[*] %s\n' "$*"; }
fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
WORK_DIR=''
SESSION_MODE=0
cleanup() {
    if (( SESSION_MODE == 0 )) && [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        find "$WORK_DIR" -depth -delete >/dev/null 2>&1 || true
    fi
}
rollback_on_exit() {
    local status=$?
    if (( status != 0 )); then
        apk_patcher_rollback "$status" >/dev/null 2>&1 || true
    fi
    cleanup
    return "$status"
}
# shellcheck disable=SC1090
source "$APK_PATCHER"

(( $# == 1 )) || fail "用法：$0 <Settings.apk>"
APK_PATH=$1
[[ -f "$APK_PATH" && ! -L "$APK_PATH" ]] || fail "找不到 Settings.apk：$APK_PATH"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd -P)/$(basename -- "$APK_PATH")
APK_DIR=$(dirname -- "$APK_PATH")
if [[ -n "${APK_PATCHER_SESSION_DIR:-}" ]]; then
    SESSION_MODE=1
    SESSION_DIR="$APK_PATCHER_SESSION_DIR"
else
    WORK_DIR=$(mktemp -d "${SETTINGS_APK_PATCH_TMPDIR:-$APK_DIR}/.settings-apk-patcher.XXXXXX")
    SESSION_DIR="$WORK_DIR"
    trap cleanup EXIT
fi
apk_patcher_open "$SESSION_DIR" "$APK_PATH" apk || fail "无法打开 Settings.apk 会话"
apk_patcher_snapshot || fail "无法保存 Settings.apk 补丁快照"
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR=$SESSION_DECODE_DIR
CLASS_PATH='com/android/settings/display/ScreenResolutionManager.smali'
METHOD_NAME='calculateHeightFromWidth(I)I'
mapfile -d '' -t CLASS_FILES < <(find "$DECODE_DIR" -type f -path "*/$CLASS_PATH" -print0)
(( ${#CLASS_FILES[@]} == 1 )) || fail "目标类数量异常：期望 1 个，实际 ${#CLASS_FILES[@]} 个"
SMALI_FILE=${CLASS_FILES[0]}
RELATIVE_SMALI_PATH=${SMALI_FILE#"$DECODE_DIR"/}
SMALI_ROOT=${RELATIVE_SMALI_PATH%%/*}
case "$SMALI_ROOT" in
    smali) DEX_ENTRY='classes.dex' ;;
    smali_classes[0-9]*)
        DEX_NUMBER=${SMALI_ROOT#smali_classes}
        [[ "$DEX_NUMBER" =~ ^[0-9]+$ ]] || fail "无法识别 DEX 目录：$SMALI_ROOT"
        DEX_ENTRY="classes${DEX_NUMBER}.dex"
        ;;
    *) fail "无法从目录识别目标 DEX：$SMALI_ROOT" ;;
esac
[[ "$(apk_patcher_entry_count "$APK_PATH" "$DEX_ENTRY")" == 1 ]] || fail "原 APK 中 $DEX_ENTRY 数量异常"

screen_resolution_method_state() {
    local smali_file=$1
    local mode=${2:-check}

    python3 - "$smali_file" "$mode" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path


smali_path = Path(sys.argv[1])
mode = sys.argv[2]
if mode not in {"check", "patch"}:
    raise SystemExit(f"不支持的 ScreenResolutionManager 操作：{mode}")

try:
    original_text = smali_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"读取 ScreenResolutionManager Smali 失败：{smali_path}：{error}")

method_pattern = re.compile(
    r"(?ms)^\.method[^\n]*\bcalculateHeightFromWidth\(I\)I[ \t]*\n.*?^\.end method[ \t]*$"
)
matches = list(method_pattern.finditer(original_text))
if len(matches) != 1:
    raise SystemExit(
        "calculateHeightFromWidth(I)I 数量应为 1，"
        f"实际为 {len(matches)}：{smali_path}"
    )


def canonical_instructions(block):
    raw_lines = []
    label_map = {}
    for raw_line in block.splitlines():
        line = raw_line.split("#", 1)[0].strip()
        raw_lines.append(line)
        if line.startswith(":") and line not in label_map:
            label_map[line] = f":label_{len(label_map)}"

    instructions = []
    for line in raw_lines:
        if not line:
            continue
        if line.startswith(":"):
            instructions.append(label_map[line])
            continue
        if line.startswith(".locals") or line.startswith(".registers"):
            instructions.append(re.sub(r"\s+", "", line))
            continue
        if line.startswith("."):
            continue
        line = re.sub(
            r":[A-Za-z0-9_.$-]+",
            lambda match: label_map.get(match.group(0), match.group(0)),
            line,
        )
        instructions.append(re.sub(r"\s+", "", line))
    return instructions


original_method = """.method private calculateHeightFromWidth(I)I
    .locals 2
    iget-object p0, p0, Lcom/android/settings/display/ScreenResolutionManager;->mDisplay:Landroid/view/Display;
    invoke-virtual {p0}, Landroid/view/Display;->getMode()Landroid/view/Display$Mode;
    move-result-object p0
    invoke-virtual {p0}, Landroid/view/Display$Mode;->getPhysicalHeight()I
    move-result v0
    int-to-float v0, v0
    const/high16 v1, 0x3f800000
    mul-float/2addr v0, v1
    invoke-virtual {p0}, Landroid/view/Display$Mode;->getPhysicalWidth()I
    move-result p0
    int-to-float p0, p0
    div-float/2addr v0, p0
    int-to-float p0, p1
    mul-float/2addr v0, p0
    float-to-int p0, v0
    return p0
.end method"""

patched_method = """.method private calculateHeightFromWidth(I)I
    .locals 5

    iget-object v0, p0, Lcom/android/settings/display/ScreenResolutionManager;->mDisplay:Landroid/view/Display;

    invoke-virtual {v0}, Landroid/view/Display;->getSupportedModes()[Landroid/view/Display$Mode;

    move-result-object v0

    array-length v1, v0

    const/4 v2, 0x0

    :resolution_mode_loop
    if-ge v2, v1, :resolution_mode_fallback

    aget-object v3, v0, v2

    invoke-virtual {v3}, Landroid/view/Display$Mode;->getPhysicalWidth()I

    move-result v4

    if-ne v4, p1, :resolution_mode_next

    invoke-virtual {v3}, Landroid/view/Display$Mode;->getPhysicalHeight()I

    move-result p0

    return p0

    :resolution_mode_next
    add-int/lit8 v2, v2, 0x1

    goto :resolution_mode_loop

    :resolution_mode_fallback
    iget-object p0, p0, Lcom/android/settings/display/ScreenResolutionManager;->mDisplay:Landroid/view/Display;

    invoke-virtual {p0}, Landroid/view/Display;->getMode()Landroid/view/Display$Mode;

    move-result-object p0

    invoke-virtual {p0}, Landroid/view/Display$Mode;->getPhysicalHeight()I

    move-result v0

    int-to-float v0, v0

    invoke-virtual {p0}, Landroid/view/Display$Mode;->getPhysicalWidth()I

    move-result p0

    int-to-float p0, p0

    div-float/2addr v0, p0

    int-to-float p0, p1

    mul-float/2addr v0, p0

    invoke-static {v0}, Ljava/lang/Math;->round(F)I

    move-result p0

    return p0
.end method"""

method_match = matches[0]
current_instructions = canonical_instructions(method_match.group(0))
if current_instructions == canonical_instructions(original_method):
    state = "original"
elif current_instructions == canonical_instructions(patched_method):
    state = "patched"
else:
    state = "unknown"

if mode == "check":
    print(state)
    raise SystemExit(0)

if state == "patched":
    print("patched 0")
    raise SystemExit(0)
if state != "original":
    raise SystemExit(
        "calculateHeightFromWidth(I)I 指令结构与当前支持版本不一致，拒绝盲目修改："
        f"{smali_path}"
    )

patched_text = (
    original_text[: method_match.start()]
    + patched_method
    + original_text[method_match.end() :]
)

try:
    file_mode = stat.S_IMODE(smali_path.stat().st_mode)
    fd, temporary_name = tempfile.mkstemp(
        prefix=f".{smali_path.name}.",
        suffix=".patch",
        dir=smali_path.parent,
    )
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as output:
            output.write(patched_text)
        os.chmod(temporary_name, file_mode)
        os.replace(temporary_name, smali_path)
    except BaseException:
        try:
            os.unlink(temporary_name)
        except FileNotFoundError:
            pass
        raise
except OSError as error:
    raise SystemExit(f"写入 ScreenResolutionManager Smali 失败：{smali_path}：{error}")

print("patched 1")
PY
}
METHOD_STATE=$(screen_resolution_method_state "$SMALI_FILE" check)
case "$METHOD_STATE" in patched) log "SKIP：$METHOD_NAME 已补丁"; exit 0 ;; original) ;; *) fail "$METHOD_NAME 指令结构与当前支持版本不一致，拒绝盲目修改" ;; esac
log "修改 $METHOD_NAME（目标 DEX：$DEX_ENTRY）"
PATCH_RESULT=$(screen_resolution_method_state "$SMALI_FILE" patch) || fail "修改目标 Smali 失败"
[[ "$PATCH_RESULT" == 'patched 1' ]] || fail "目标 Smali 未产生预期修改：$PATCH_RESULT"
[[ "$(screen_resolution_method_state "$SMALI_FILE" check)" == 'patched' ]] || fail "修改后的 Smali 校验失败"


apk_patcher_record_entry "$DEX_ENTRY" || fail "无法登记 Settings.apk 目标 DEX"
if (( SESSION_MODE == 1 )); then
    log "已登记 Settings.apk 的 $DEX_ENTRY 修改，等待统一回编译"
else
    apk_patcher_finalize || fail "Settings.apk 最终回编译失败"
    log "APPLY：补丁完成：$APK_PATH"
fi
