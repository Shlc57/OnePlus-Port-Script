#!/usr/bin/env bash
set -Eeuo pipefail

HAPTIC_CLASS_PATH='com/android/settings/utils/SettingsFeatures.smali'
HAPTIC_METHOD_NAME='isSupportSettingsHaptic(Landroid/content/Context;)Z'
SCREEN_RESOLUTION_CLASS_PATH='com/android/settings/display/ScreenResolutionManager.smali'
SCREEN_RESOLUTION_METHOD_NAME='calculateHeightFromWidth(I)I'
# Smali 内部类名中的美元符号是字面量，不应由 Shell 展开。
# shellcheck disable=SC2016
FACE_ENROLL_FINISH_CLASS_PATH='com/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment$9.smali'
FACE_ENROLL_FINISH_METHOD_NAME='onEnrollmentProgress(I)V'
PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SIGNING_BLOCK_TOOL="$PATCHER_DIR/apk_signing_block.py"

PATCH_KIND=''
CLASS_PATH=''
METHOD_NAME=''
PATCH_DESCRIPTION=''

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

archive_entry_count() {
    local apk=$1
    local entry=$2

    python3 - "$apk" "$entry" <<'PY'
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
except (OSError, EOFError, IndexError, MemoryError, OverflowError, RuntimeError,
        ValueError, zipfile.BadZipFile, zipfile.LargeZipFile) as error:
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
    except (OSError, EOFError, IndexError, MemoryError, OverflowError, RuntimeError,
            ValueError, zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error) as error:
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


before, before_infos = open_archive(before_path)
after, after_infos = open_archive(after_path)
try:
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
    before.close()
    after.close()
PY
}

haptic_method_state() {
    local smali_file=$1

    awk '
        function normalize_instruction(line) {
            sub(/[[:space:]]*#.*/, "", line)
            sub(/^[[:space:]]+/, "", line)
            sub(/[[:space:]]+$/, "", line)
            if (line == "" || substr(line, 1, 1) == "." || substr(line, 1, 1) == ":") {
                return ""
            }
            return line
        }
        function finish_method() {
            if (first_instruction ~ /^const\/4[[:space:]]+v0,[[:space:]]+0x0$/ && second_instruction ~ /^if-nez[[:space:]]+p0,[[:space:]]+:.+$/ && third_instruction ~ /^return[[:space:]]+v0$/) {
                zero_count++
            } else if (first_instruction ~ /^const\/4[[:space:]]+v0,[[:space:]]+0x1$/ && second_instruction ~ /^if-nez[[:space:]]+p0,[[:space:]]+:.+$/ && third_instruction ~ /^return[[:space:]]+v0$/) {
                one_count++
            }
        }
        /^[[:space:]]*\.method[[:space:]].*isSupportSettingsHaptic\(Landroid\/content\/Context;\)Z[[:space:]]*$/ {
            method_count++
            in_method=1
            instruction_count=0
            first_instruction=""
            second_instruction=""
            third_instruction=""
            next
        }
        in_method && /^[[:space:]]*\.end method[[:space:]]*$/ {
            finish_method()
            in_method=0
            next
        }
        in_method {
            normalized=normalize_instruction($0)
            if (normalized != "" && instruction_count < 3) {
                instruction_count++
                if (instruction_count == 1) {
                    first_instruction=normalized
                } else if (instruction_count == 2) {
                    second_instruction=normalized
                } else {
                    third_instruction=normalized
                }
            }
        }
        END {
            printf "%d %d %d\n", method_count, zero_count, one_count
        }
    ' "$smali_file"
}

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
current_step_getter = (
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
    "->-$$Nest$fgetmCurrentEnrollAnimationStep("
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;)I"
)
current_step_setter = (
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
    "->-$$Nest$fputmCurrentEnrollAnimationStep("
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;I)V"
)
update_help_method = (
    "Lcom/android/settings/faceunlock/"
    "MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;"
    "->-$$Nest$mupdateFaceHelpInfo("
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
    '->-$$Nest$fputmFaceEnrollSucceed('
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
    marker_counts == (1, 1, 1, 1, 1)
    and activity_guard_count == 1
    and original_shape
)
callback_original = (
    marker_counts == (0, 0, 0, 0, 0)
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

    invoke-static {v0, v1}, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;->-$$Nest$mupdateFaceHelpInfo(Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;I)V

    return-void

    :face_enroll_finish_complete
""",
    1,
)

activity_guard = "    if-eqz v0, :cond_0\n"
if patched_block.count(activity_guard) != 1:
    raise SystemExit(f"无法唯一定位 Activity 有效性判断：{smali_path}")
initialize_step = """
    invoke-static {p1}, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;->-$$Nest$fgetmCurrentEnrollAnimationStep(Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;)I

    move-result v0

    if-nez v0, :face_enroll_finish_initialized

    const/4 v0, 0x1

    invoke-static {p1, v0}, Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;->-$$Nest$fputmCurrentEnrollAnimationStep(Lcom/android/settings/faceunlock/MiuiNormalCameraMultiFaceInput$NewMultiFaceEnrollFragment;I)V

    :face_enroll_finish_initialized
"""
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

validate_and_install_apk() {
    local excluded_entry=$1
    local expected_entry_file=${2:-}

    log "回插原 APK Signing Block"
    python3 "$SIGNING_BLOCK_TOOL" insert "$PATCHED_APK" "$SIGNING_BLOCK_BEFORE"
    python3 "$SIGNING_BLOCK_TOOL" extract "$PATCHED_APK" "$SIGNING_BLOCK_AFTER" >/dev/null
    cmp -s "$SIGNING_BLOCK_BEFORE" "$SIGNING_BLOCK_AFTER" ||
        fail "更新后 APK Signing Block 内容发生变化"
    "$ZIPALIGN_COMMAND" -c -P 16 4 "$PATCHED_APK" ||
        fail "更新后的 APK 未通过 zipalign 校验"

    unzip -tq "$PATCHED_APK" >/dev/null || fail "更新后的 APK 完整性校验失败"
    if [[ -n "$expected_entry_file" ]]; then
        cmp -s "$expected_entry_file" <(unzip -p "$PATCHED_APK" "$excluded_entry") ||
            fail "$excluded_entry 未正确写入 APK"
    fi

    compare_archive_contract "$APK_PATH" "$PATCHED_APK" "$excluded_entry" ||
        fail "更新后 APK 的非目标归档契约发生变化"

    REPLACEMENT_PATH=$(mktemp "$APK_DIR/.Settings.apk.patch.XXXXXX")
    rm -f -- "$REPLACEMENT_PATH"
    cp -a -- "$PATCHED_APK" "$REPLACEMENT_PATH"
    mv -fT -- "$REPLACEMENT_PATH" "$APK_PATH"
    REPLACEMENT_PATH=''

    log "APPLY：补丁完成：$APK_PATH"
    log "已原样保留 Signing Block 与 META-INF 证书材料，但 DEX 修改后 v1/v2/v3 内容完整性签名必然失效"
    log "本产物仅适用于已确认系统扫描绕过完整性校验、仍需保留原证书身份的 ROM；不能作为普通 APK 安装"
}

finish_if_already_patched() {
    if "$ZIPALIGN_COMMAND" -c -P 16 4 "$APK_PATH" >/dev/null 2>&1; then
        log "SKIP：$METHOD_NAME 已补丁，且 APK 对齐正常"
        exit 0
    fi

    log "$METHOD_NAME 已补丁，但 APK 未对齐；仅修复归档对齐"
    "$ZIPALIGN_COMMAND" -f -P 16 4 "$APK_PATH" "$ALIGNED_APK" ||
        fail "zipalign 对齐失败"
    compare_archive_contract "$APK_PATH" "$ALIGNED_APK" "" ||
        fail "归档对齐不应改变 APK 条目顺序、压缩方式或内容"
    mv -- "$ALIGNED_APK" "$PATCHED_APK"
    validate_and_install_apk ""
    exit 0
}

(( $# == 2 )) || fail "用法：$0 <haptic|screen-resolution|face-enroll-finish> <Settings.apk>"
PATCH_KIND=$1
APK_PATH=$2

case "$PATCH_KIND" in
    haptic)
        CLASS_PATH=$HAPTIC_CLASS_PATH
        METHOD_NAME=$HAPTIC_METHOD_NAME
        PATCH_DESCRIPTION='Settings 触感支持'
        ;;
    screen-resolution)
        CLASS_PATH=$SCREEN_RESOLUTION_CLASS_PATH
        METHOD_NAME=$SCREEN_RESOLUTION_METHOD_NAME
        PATCH_DESCRIPTION='ScreenResolutionManager 分辨率高度'
        ;;
    face-enroll-finish)
        CLASS_PATH=$FACE_ENROLL_FINISH_CLASS_PATH
        METHOD_NAME=$FACE_ENROLL_FINISH_METHOD_NAME
        PATCH_DESCRIPTION='标准 FaceManager 录入进度与完成收尾'
        ;;
    *)
        fail "不支持的 Settings APK 补丁类型：$PATCH_KIND"
        ;;
esac

for command_name in awk basename cmp cp dirname find mkdir mktemp mv python3 rm sort tail unzip zip; do
    require_command "$command_name"
done
resolve_apktool
resolve_zipalign
[[ -r "$SIGNING_BLOCK_TOOL" ]] || fail "找不到 Signing Block 工具：$SIGNING_BLOCK_TOOL"

[[ -f "$APK_PATH" ]] || fail "找不到 Settings.apk：$APK_PATH"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd)/$(basename -- "$APK_PATH")
APK_DIR=$(dirname -- "$APK_PATH")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/settings-apk-patcher.${PATCH_KIND}.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR="$WORK_DIR/decoded"
REBUILT_APK="$WORK_DIR/rebuilt.apk"
DEX_DIR="$WORK_DIR/dex"
PATCHED_APK="$WORK_DIR/Settings.apk.patched"
ALIGNED_APK="$WORK_DIR/Settings.apk.aligned"
SIGNING_BLOCK_BEFORE="$WORK_DIR/apk-signing-block.before"
SIGNING_BLOCK_AFTER="$WORK_DIR/apk-signing-block.after"

log "记录原 APK 的 Signing Block"
SIGNING_BLOCK_PAIR_IDS=$(
    python3 "$SIGNING_BLOCK_TOOL" extract "$APK_PATH" "$SIGNING_BLOCK_BEFORE"
)
log "已保存原 APK Signing Block Pair IDs：$SIGNING_BLOCK_PAIR_IDS"

log "反编译 Settings.apk（$PATCH_DESCRIPTION）"
"${APKTOOL_COMMAND[@]}" d -f -r "$APK_PATH" -o "$DECODE_DIR"

mapfile -d '' -t CLASS_FILES < <(
    find "$DECODE_DIR" -type f -path "*/$CLASS_PATH" -print0
)

(( ${#CLASS_FILES[@]} == 1 )) ||
    fail "目标类数量异常：期望 1 个，实际 ${#CLASS_FILES[@]} 个"

SMALI_FILE=${CLASS_FILES[0]}
RELATIVE_SMALI_PATH=${SMALI_FILE#"$DECODE_DIR"/}
SMALI_ROOT=${RELATIVE_SMALI_PATH%%/*}

case "$SMALI_ROOT" in
    smali)
        DEX_ENTRY='classes.dex'
        ;;
    smali_classes[0-9]*)
        DEX_NUMBER=${SMALI_ROOT#smali_classes}
        [[ "$DEX_NUMBER" =~ ^[0-9]+$ ]] || fail "无法识别 DEX 目录：$SMALI_ROOT"
        DEX_ENTRY="classes${DEX_NUMBER}.dex"
        ;;
    *)
        fail "无法从目录识别目标 DEX：$SMALI_ROOT"
        ;;
esac

DEX_ENTRY_COUNT=$(archive_entry_count "$APK_PATH" "$DEX_ENTRY")
(( DEX_ENTRY_COUNT == 1 )) ||
    fail "原 APK 中 $DEX_ENTRY 数量异常：期望 1 个，实际 $DEX_ENTRY_COUNT 个"

case "$PATCH_KIND" in
    haptic)
        read -r METHOD_COUNT ZERO_COUNT ONE_COUNT < <(haptic_method_state "$SMALI_FILE")
        (( METHOD_COUNT == 1 )) ||
            fail "目标方法数量异常：期望 1 个，实际 $METHOD_COUNT 个"

        if (( ZERO_COUNT == 0 && ONE_COUNT == 1 )); then
            finish_if_already_patched
        fi

        (( ZERO_COUNT == 1 && ONE_COUNT == 0 )) ||
            fail "目标指令结构异常：0x0=$ZERO_COUNT，0x1=$ONE_COUNT，拒绝盲目修改"

        log "修改 $METHOD_NAME（目标 DEX：$DEX_ENTRY）"
        awk '
            function normalize_instruction(line) {
                sub(/[[:space:]]*#.*/, "", line)
                sub(/^[[:space:]]+/, "", line)
                sub(/[[:space:]]+$/, "", line)
                if (line == "" || substr(line, 1, 1) == "." || substr(line, 1, 1) == ":") {
                    return ""
                }
                return line
            }
            /^[[:space:]]*\.method[[:space:]].*isSupportSettingsHaptic\(Landroid\/content\/Context;\)Z[[:space:]]*$/ {
                in_method=1
                instruction_count=0
            }
            in_method {
                normalized=normalize_instruction($0)
                if (normalized != "") {
                    instruction_count++
                    if (instruction_count == 1 && normalized ~ /^const\/4[[:space:]]+v0,[[:space:]]+0x0$/) {
                        sub(/0x0/, "0x1")
                        patched=1
                    }
                }
            }
            { print }
            in_method && /^[[:space:]]*\.end method[[:space:]]*$/ {
                in_method=0
            }
            END {
                if (!patched) {
                    exit 1
                }
            }
        ' "$SMALI_FILE" > "$SMALI_FILE.new" || fail "修改目标 Smali 失败"
        mv -- "$SMALI_FILE.new" "$SMALI_FILE"

        read -r METHOD_COUNT ZERO_COUNT ONE_COUNT < <(haptic_method_state "$SMALI_FILE")
        (( METHOD_COUNT == 1 && ZERO_COUNT == 0 && ONE_COUNT == 1 )) ||
            fail "修改后的 Smali 校验失败"
        ;;
    screen-resolution)
        METHOD_STATE=$(screen_resolution_method_state "$SMALI_FILE" check)
        case "$METHOD_STATE" in
            patched)
                finish_if_already_patched
                ;;
            original)
                ;;
            *)
                fail "$METHOD_NAME 指令结构与当前支持版本不一致，拒绝盲目修改"
                ;;
        esac

        log "修改 $METHOD_NAME（目标 DEX：$DEX_ENTRY）"
        PATCH_RESULT=$(screen_resolution_method_state "$SMALI_FILE" patch) ||
            fail "修改目标 Smali 失败"
        [[ "$PATCH_RESULT" == 'patched 1' ]] ||
            fail "目标 Smali 未产生预期修改：$PATCH_RESULT"
        [[ "$(screen_resolution_method_state "$SMALI_FILE" check)" == 'patched' ]] ||
            fail "修改后的 Smali 校验失败"
        ;;
    face-enroll-finish)
        METHOD_STATE=$(face_enroll_finish_method_state "$SMALI_FILE" check)
        case "$METHOD_STATE" in
            patched)
                finish_if_already_patched
                ;;
            original)
                ;;
            *)
                fail "$METHOD_NAME 指令结构与当前支持版本不一致，拒绝盲目修改"
                ;;
        esac

        log "修改 $METHOD_NAME（目标 DEX：$DEX_ENTRY）"
        PATCH_RESULT=$(face_enroll_finish_method_state "$SMALI_FILE" patch) ||
            fail "修改目标 Smali 失败"
        [[ "$PATCH_RESULT" == 'patched 1' ]] ||
            fail "目标 Smali 未产生预期修改：$PATCH_RESULT"
        [[ "$(face_enroll_finish_method_state "$SMALI_FILE" check)" == 'patched' ]] ||
            fail "修改后的 Smali 校验失败"
        ;;
esac

log "回编译 APK 以生成新的 $DEX_ENTRY"
"${APKTOOL_COMMAND[@]}" b "$DECODE_DIR" -o "$REBUILT_APK"

mkdir -p "$DEX_DIR"
unzip -p "$REBUILT_APK" "$DEX_ENTRY" > "$DEX_DIR/$DEX_ENTRY" ||
    fail "回编译结果中缺少 $DEX_ENTRY"
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
validate_and_install_apk \
    "$DEX_ENTRY" \
    "$DEX_DIR/$DEX_ENTRY"
