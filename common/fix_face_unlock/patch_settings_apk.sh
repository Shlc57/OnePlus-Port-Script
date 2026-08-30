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
# shellcheck disable=SC2016
CLASS_PATH='com/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment$9.smali'
METHOD_NAME='onEnrollmentProgress(I)V'
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

face_enroll_finish_method_state() {
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
outer_smali_path = smali_path.with_name(
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment.smali"
)
mode = sys.argv[2]
if mode not in {"check", "patch"}:
    raise SystemExit(f"不支持的人脸录入收尾操作：{mode}")

try:
    original_text = smali_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"读取人脸录入回调 Smali 失败：{smali_path}：{error}")
try:
    outer_original_text = outer_smali_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(
        f"读取人脸录入页面 Smali 失败：{outer_smali_path}：{error}"
    )

method_pattern = re.compile(
    r"(?ms)^\.method[^\n]*\bonEnrollmentProgress\(I\)V[ \t]*\n.*?^\.end method[ \t]*$"
)
matches = list(method_pattern.finditer(original_text))
if len(matches) != 1:
    raise SystemExit(
        "onEnrollmentProgress(I)V 数量应为 1，"
        f"实际为 {len(matches)}：{smali_path}"
    )

method_block = matches[0].group(0)
start_method_pattern = re.compile(
    r"(?ms)^\.method[^\n]*\bstartEnrollFace\(\)V[ \t]*\n.*?^\.end method[ \t]*$"
)
start_matches = list(start_method_pattern.finditer(outer_original_text))
if len(start_matches) != 1:
    raise SystemExit(
        "startEnrollFace()V 数量应为 1，"
        f"实际为 {len(start_matches)}：{outer_smali_path}"
    )
start_method_block = start_matches[0].group(0)

progress_view_method_pattern = re.compile(
    r"(?ms)^\.method[^\n]*\binitProgressView\(\)V[ \t]*\n.*?^\.end method[ \t]*$"
)
progress_view_matches = list(
    progress_view_method_pattern.finditer(outer_original_text)
)
if len(progress_view_matches) != 1:
    raise SystemExit(
        "initProgressView()V 数量应为 1，"
        f"实际为 {len(progress_view_matches)}：{outer_smali_path}"
    )
progress_view_method_block = progress_view_matches[0].group(0)
nest_accessor_prefixes = ("-$Nest$", "-$$Nest$")
callback_accessor_prefixes = [
    prefix
    for prefix in nest_accessor_prefixes
    if f"->{prefix}" in method_block
]
accessor_prefix_consistent = len(callback_accessor_prefixes) == 1
nest_accessor_prefix = (
    callback_accessor_prefixes[0] if accessor_prefix_consistent else "\\x00"
)

current_step_getter = (
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
    f"->{nest_accessor_prefix}fgetmCurrentEnrollAnimationStep("
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;)I"
)
current_step_setter = (
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
    f"->{nest_accessor_prefix}fputmCurrentEnrollAnimationStep("
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;I)V"
)
update_help_method = (
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
    f"->{nest_accessor_prefix}mupdateFaceHelpInfo("
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;I)V"
)

progress_guard_count = len(
    re.findall(
        r"(?m)^[ \t]*if-eqz[ \t]+p1,[ \t]+:[A-Za-z0-9_.$-]+[ \t]*$",
        method_block,
    )
)
progress_help_code_count = len(
    re.findall(
        r"(?m)^[ \t]*const/16[ \t]+v1,[ \t]+0x13[ \t]*$",
        method_block,
    )
)
activity_guard_count = len(
    re.findall(
        r"(?m)^[ \t]*if-eqz[ \t]+v0,[ \t]+:[A-Za-z0-9_.$-]+[ \t]*$",
        method_block,
    )
)
marker_counts = (
    progress_guard_count,
    progress_help_code_count,
    method_block.count(update_help_method),
    method_block.count(current_step_getter),
    method_block.count(current_step_setter),
)
required_original_fragments = (
    '.locals 2',
    'const-string v1, "enrollCallback, onEnrollmentProgress :"',
    'iget-object v0, p1, Lcom/android/settings/faceunlock/'
    'MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;'
    '->mActivity:Landroid/app/Activity;',
    'Lcom/android/settings/faceunlock/'
    'MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;'
    f'->{nest_accessor_prefix}fputmFaceEnrollSucceed('
    'Lcom/android/settings/faceunlock/'
    'MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;Z)V',
)
original_shape = all(
    method_block.count(fragment) == 1
    for fragment in required_original_fragments
)

start_progress_call = (
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
    "->updateFaceHelpInfo(I)V"
)
start_progress_code_count = len(
    re.findall(
        r"(?m)^[ \t]*const/16[ \t]+v2,[ \t]+0x13[ \t]*$",
        start_method_block,
    )
)
start_progress_call_count = start_method_block.count(start_progress_call)
speed_2x_count = len(
    re.findall(
        r"(?m)^[ \t]*const/high16[ \t]+v2,[ \t]+0x40000000(?:[ \t]+#.*)?$",
        progress_view_method_block,
    )
)
speed_3x_count = len(
    re.findall(
        r"(?m)^[ \t]*const/high16[ \t]+v2,[ \t]+0x40400000(?:[ \t]+#.*)?$",
        progress_view_method_block,
    )
)

callback_patched = (
    accessor_prefix_consistent
    and marker_counts == (1, 1, 1, 1, 1)
    and activity_guard_count == 1
    and original_shape
)
callback_original = (
    accessor_prefix_consistent
    and marker_counts == (0, 0, 0, 0, 0)
    and activity_guard_count == 1
    and original_shape
)
start_patched = (start_progress_code_count, start_progress_call_count) == (1, 1)
start_original = (start_progress_code_count, start_progress_call_count) == (0, 0)
speed_patched = (speed_2x_count, speed_3x_count) == (0, 1)
speed_original = (speed_2x_count, speed_3x_count) == (1, 0)

if callback_patched and start_patched and speed_patched:
    state = "patched"
elif callback_original and start_original and speed_original:
    state = "original"
else:
    state = "unknown"

if mode == "check":
    print(state)
    raise SystemExit(0)

if state != "original":
    raise SystemExit(
        "onEnrollmentProgress(I)V 指令结构不是受支持的原始状态："
        f"{state}：{smali_path}"
    )

locals_anchor = "    .locals 2\n"
if method_block.count(locals_anchor) != 1:
    raise SystemExit(f"无法唯一定位方法寄存器声明：{smali_path}")
patched_block = method_block.replace(
    locals_anchor,
    locals_anchor + """

    if-eqz p1, :face_enroll_finish_complete

    iget-object v0, p0, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment$9;->this$0:Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;

    const/16 v1, 0x13

    invoke-static {v0, v1}, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;->%smupdateFaceHelpInfo(Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;I)V

    return-void

    :face_enroll_finish_complete
""" % nest_accessor_prefix,
    1,
)

activity_guard = "    if-eqz v0, :cond_0\n"
if patched_block.count(activity_guard) != 1:
    raise SystemExit(f"无法唯一定位 Activity 有效性判断：{smali_path}")
initialize_step = """
    invoke-static {p1}, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;->%sfgetmCurrentEnrollAnimationStep(Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;)I

    move-result v0

    if-nez v0, :face_enroll_finish_initialized

    const/4 v0, 0x1

    invoke-static {p1, v0}, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;->%sfputmCurrentEnrollAnimationStep(Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;I)V

    :face_enroll_finish_initialized
""" % (nest_accessor_prefix, nest_accessor_prefix)
patched_block = patched_block.replace(
    activity_guard,
    activity_guard + initialize_step,
    1,
)

updated_text = (
    original_text[: matches[0].start()]
    + patched_block
    + original_text[matches[0].end() :]
)

worker_anchor = (
    "    iget-object v2, p0, Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
    "->mFaceUnlockManager:Lcom/android/settings/faceunlock/"
    "KeyguardSettingsFaceUnlockManager;\n\n"
    "    new-instance v3, Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment"
    "$$ExternalSyntheticLambda4;\n"
)
if start_method_block.count(worker_anchor) != 1:
    raise SystemExit(f"无法唯一定位标准人脸录入启动位置：{outer_smali_path}")
start_progress = """    const/16 v2, 0x13

    invoke-direct {p0, v2}, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;->updateFaceHelpInfo(I)V

"""
patched_start_method_block = start_method_block.replace(
    worker_anchor,
    start_progress + worker_anchor,
    1,
)

speed_pattern = re.compile(
    r"(?m)^(?P<prefix>[ \t]*const/high16[ \t]+v2,[ \t]+)"
    r"0x40000000(?:[ \t]+#.*)?$"
)
patched_progress_view_method_block, speed_patch_count = speed_pattern.subn(
    r"\g<prefix>0x40400000    # 3.0f",
    progress_view_method_block,
    count=1,
)
if speed_patch_count != 1:
    raise SystemExit(f"无法唯一调整五段人脸录入动画速度：{outer_smali_path}")

outer_updated_text = outer_original_text
outer_replacements = (
    (
        progress_view_matches[0].start(),
        progress_view_matches[0].end(),
        patched_progress_view_method_block,
    ),
    (
        start_matches[0].start(),
        start_matches[0].end(),
        patched_start_method_block,
    ),
)
for start, end, replacement in sorted(outer_replacements, reverse=True):
    outer_updated_text = (
        outer_updated_text[:start] + replacement + outer_updated_text[end:]
    )

def replace_file(path, text, description):
    file_mode = stat.S_IMODE(path.stat().st_mode)
    try:
        with tempfile.NamedTemporaryFile(
            mode="w",
            encoding="utf-8",
            newline="",
            prefix=f".{path.name}.",
            suffix=".tmp",
            dir=path.parent,
            delete=False,
        ) as temporary:
            temporary.write(text)
            temporary_name = temporary.name
        try:
            os.chmod(temporary_name, file_mode)
            os.replace(temporary_name, path)
        except Exception:
            os.unlink(temporary_name)
            raise
    except OSError as error:
        raise SystemExit(f"写入{description}失败：{path}：{error}")


replace_file(outer_smali_path, outer_updated_text, "人脸录入页面 Smali")
replace_file(smali_path, updated_text, "人脸录入回调 Smali")

print("patched 1")
PY
}
METHOD_STATE=$(face_enroll_finish_method_state "$SMALI_FILE" check)
case "$METHOD_STATE" in patched) log "SKIP：$METHOD_NAME 已补丁"; exit 0 ;; original) ;; *) fail "$METHOD_NAME 指令结构与当前支持版本不一致，拒绝盲目修改" ;; esac
log "修改 $METHOD_NAME（目标 DEX：$DEX_ENTRY）"
PATCH_RESULT=$(face_enroll_finish_method_state "$SMALI_FILE" patch) || fail "修改目标 Smali 失败"
[[ "$PATCH_RESULT" == 'patched 1' ]] || fail "目标 Smali 未产生预期修改：$PATCH_RESULT"
[[ "$(face_enroll_finish_method_state "$SMALI_FILE" check)" == 'patched' ]] || fail "修改后的 Smali 校验失败"


apk_patcher_record_entry "$DEX_ENTRY" || fail "无法登记 Settings.apk 目标 DEX"
if (( SESSION_MODE == 1 )); then
    log "已登记 Settings.apk 的 $DEX_ENTRY 修改，等待统一回编译"
else
    apk_patcher_finalize || fail "Settings.apk 最终回编译失败"
    log "APPLY：补丁完成：$APK_PATH"
fi
