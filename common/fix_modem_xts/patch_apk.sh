#!/usr/bin/env bash
set -Eeuo pipefail

XTS_CLASS_PATH='com/android/phone/XtsApp.smali'
SCREEN_STATUS_CLASS_PATH='com/xiaomi/mirilhook/MiRilHook.smali'
PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PORT_ROOT=$(cd -- "$PATCHER_DIR/../.." && pwd)
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
        try:
            before_content = before.read(before_info)
            after_content = after.read(after_info)
        except (EOFError, IndexError, MemoryError, OverflowError, RuntimeError,
                ValueError, zipfile.BadZipFile, zipfile.LargeZipFile, zlib.error) as error:
            fail(f"条目 {before_info.filename!r} 内容读取失败：{error}")
        if before_content != after_content:
            fail(f"非目标条目内容变化：{before_info.filename!r}")
finally:
    before.close()
    after.close()
PY
}

smali_patch_state() {
    local smali_file=$1
    local mode=$2
    local profile=$3

    python3 - "$smali_file" "$mode" "$profile" <<'PY'
import re
import sys
from pathlib import Path


class PatchError(Exception):
    pass


path = Path(sys.argv[1])
mode = sys.argv[2]
profile = sys.argv[3]
if mode not in {"check", "patch"}:
    raise SystemExit("[!] 无效的 Smali 操作模式")

spec_groups = {
    "xts": {
        "ver": {
            "descriptor": "onInitVerInfo(Lcom/xiaomi/modem/OemHookAgent;)V",
            "markers": (
                "->getModemHalChipId(Lcom/xiaomi/modem/OemHookAgent;)I",
                "->getModemChipId(Lcom/xiaomi/modem/OemHookAgent;)I",
                "->getBuildProfile(Lcom/xiaomi/modem/OemHookAgent;)Ljava/lang/String;",
                "->getManufacturerId(Lcom/xiaomi/modem/OemHookAgent;)I",
                "->getOemProductFlag(Lcom/xiaomi/modem/OemHookAgent;)I",
                "->isHalDecoupled(Lcom/xiaomi/modem/OemHookAgent;)Z",
            ),
            "payload": ("return-void",),
            "patched_patterns": (r"return-void",),
        },
        "xts": {
            "descriptor": "isXtsSupported()Z",
            "markers": (
                '"isXtsSupported"',
                "Lcom/android/phone/XtsApp;->mIsHalDecoupled:Z",
                "Lcom/android/phone/XtsApp;->mManufacturerId:I",
                "Lcom/android/phone/XtsApp;->mHalChipId:I",
                "Lcom/android/phone/XtsApp;->mOemProjectFlag:I",
            ),
            "payload": ("const/4 v0, 0x0", "return v0"),
            "patched_patterns": (
                r"const/4\s+v0,\s+0x0",
                r"return\s+v0",
            ),
        },
    },
    "screen_status": {
        "screen_status": {
            "descriptor": "onHookNotifyScreenStatusSync(I)Ljava/nio/ByteBuffer;",
            "markers": (
                "->onHookPkNotifyScreenStatus(I)[B",
                "->onHookSendSync([BI)Ljava/nio/ByteBuffer;",
            ),
            "payload": ("const/4 v0, 0x0", "return-object v0"),
            "patched_patterns": (
                r"const/4\s+v0,\s+0x0",
                r"return-object\s+v0",
            ),
        },
    },
}

if profile not in spec_groups:
    raise SystemExit("[!] 无效的 Smali 补丁 profile")
specs = spec_groups[profile]


def normalize_instruction(line):
    line = line.split("#", 1)[0].strip()
    if not line or line.startswith(".") or line.startswith(":"):
        return None
    return line


def find_sections(lines):
    sections = {}
    for key, spec in specs.items():
        pattern = re.compile(
            r"^\s*\.method\s+.*" + re.escape(spec["descriptor"]) + r"\s*$"
        )
        matches = []
        for start, line in enumerate(lines):
            if not pattern.match(line.rstrip("\r\n")):
                continue
            for end in range(start + 1, len(lines)):
                if re.match(r"^\s*\.end method\s*$", lines[end].rstrip("\r\n")):
                    matches.append((start, end))
                    break
            else:
                raise PatchError("{} 缺少 .end method".format(spec["descriptor"]))
        if len(matches) != 1:
            raise PatchError(
                "{} 数量异常：期望 1 个，实际 {} 个".format(
                    spec["descriptor"], len(matches)
                )
            )
        sections[key] = matches[0]
    return sections


def inspect(lines, sections):
    states = {}
    for key, spec in specs.items():
        start, end = sections[key]
        block = "".join(lines[start : end + 1])
        instructions = []
        for line in lines[start + 1 : end]:
            instruction = normalize_instruction(line)
            if instruction is not None:
                instructions.append(instruction)

        patterns = spec["patched_patterns"]
        patched = bool(
            len(instructions) >= len(patterns)
            and all(
                re.fullmatch(pattern, instructions[index])
                for index, pattern in enumerate(patterns)
            )
        )

        if not patched:
            missing = [marker for marker in spec["markers"] if marker not in block]
            if missing:
                raise PatchError(
                    "{} 原始结构不符合预期，缺失标记：{}".format(
                        spec["descriptor"], ", ".join(missing)
                    )
                )
        states[key] = patched
    return states


try:
    lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
    sections = find_sections(lines)
    states = inspect(lines, sections)
    changed = 0

    if mode == "patch":
        for key in sorted(sections, key=lambda item: sections[item][0], reverse=True):
            if states[key]:
                continue
            start, end = sections[key]
            register_lines = []
            for index in range(start + 1, end):
                if re.match(r"^\s*\.(?:locals|registers)\s+\d+\s*$", lines[index].rstrip("\r\n")):
                    register_lines.append(index)
            if len(register_lines) != 1:
                raise PatchError(
                    "{} 的寄存器声明数量异常：期望 1 个，实际 {} 个".format(
                        specs[key]["descriptor"], len(register_lines)
                    )
                )

            register_index = register_lines[0]
            register_line = lines[register_index]
            newline = "\r\n" if register_line.endswith("\r\n") else "\n"
            indent = re.match(r"^(\s*)", register_line).group(1)
            payload = []
            for instruction in specs[key]["payload"]:
                payload.append(indent + instruction + newline)
                payload.append(newline)
            lines[register_index + 1 : register_index + 1] = payload
            changed += 1

        path.write_text("".join(lines), encoding="utf-8")
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        sections = find_sections(lines)
        states = inspect(lines, sections)
        if not all(states.values()):
            raise PatchError("写入后的目标方法校验失败")

    print(
        " ".join(
            [str(int(states[key])) for key in specs]
            + [str(changed)]
        )
    )
except (OSError, PatchError) as error:
    print("[!] {}".format(error), file=sys.stderr)
    raise SystemExit(1)
PY
}

validate_and_install_apk() {
    local excluded_entry=$1
    local expected_entry_file=$2

    log "回插原 APK Signing Block"
    python3 "$SIGNING_BLOCK_TOOL" insert "$PATCHED_APK" "$SIGNING_BLOCK_BEFORE"
    python3 "$SIGNING_BLOCK_TOOL" extract "$PATCHED_APK" "$SIGNING_BLOCK_AFTER" >/dev/null
    cmp -s "$SIGNING_BLOCK_BEFORE" "$SIGNING_BLOCK_AFTER" ||
        fail "更新后 APK Signing Block 内容发生变化"
    "$ZIPALIGN_COMMAND" -c -P 16 4 "$PATCHED_APK" ||
        fail "更新后的 APK 未通过 zipalign 校验"

    unzip -tq "$PATCHED_APK" >/dev/null || fail "更新后的 APK 完整性校验失败"
    cmp -s "$expected_entry_file" <(unzip -p "$PATCHED_APK" "$excluded_entry") ||
        fail "$excluded_entry 未正确写入 APK"

    compare_archive_contract "$APK_PATH" "$PATCHED_APK" "$excluded_entry" ||
        fail "更新后 APK 的非目标归档契约发生变化"

    log "恢复原 TeleService.apk 文件属性"
    cp --attributes-only --preserve=all -- "$APK_PATH" "$PATCHED_APK" ||
        fail "无法恢复原 TeleService.apk 文件属性"

    REPLACEMENT_PATH=$(mktemp "$APK_DIR/.TeleService.apk.patch.XXXXXX")
    cp -a -- "$PATCHED_APK" "$REPLACEMENT_PATH"
    mv -fT -- "$REPLACEMENT_PATH" "$APK_PATH"
    REPLACEMENT_PATH=''

    log "APPLY：补丁完成：$APK_PATH"
    log "已原样保留 Signing Block 与 META-INF 证书材料，但 DEX 修改后 v1/v2/v3 内容完整性签名必然失效"
    log "本产物仅适用于已确认系统扫描绕过完整性校验、仍需保留原证书身份的 ROM；不能作为普通 APK 安装"
}

(( $# == 1 )) || fail "用法：$0 <TeleService.apk>"
APK_PATH=$1

for command_name in awk basename cmp cp dirname find mkdir mktemp mv python3 rm sort tail unzip zip; do
    require_command "$command_name"
done
resolve_apktool
resolve_zipalign
[[ -r "$SIGNING_BLOCK_TOOL" ]] || fail "找不到 Signing Block 工具：$SIGNING_BLOCK_TOOL"

[[ -f "$APK_PATH" ]] || fail "找不到 TeleService.apk：$APK_PATH"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd)/$(basename -- "$APK_PATH")
APK_DIR=$(dirname -- "$APK_PATH")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fix-modem-xts.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR="$WORK_DIR/decoded"
REBUILT_APK="$WORK_DIR/rebuilt.apk"
DEX_DIR="$WORK_DIR/dex"
PATCHED_APK="$WORK_DIR/TeleService.apk.patched"
ALIGNED_APK="$WORK_DIR/TeleService.apk.aligned"
SIGNING_BLOCK_BEFORE="$WORK_DIR/apk-signing-block.before"
SIGNING_BLOCK_AFTER="$WORK_DIR/apk-signing-block.after"

log "记录原 APK 的 Signing Block"
SIGNING_BLOCK_PAIR_IDS=$(
    python3 "$SIGNING_BLOCK_TOOL" extract "$APK_PATH" "$SIGNING_BLOCK_BEFORE"
)
log "已保存原 APK Signing Block Pair IDs：$SIGNING_BLOCK_PAIR_IDS"

log "反编译 TeleService.apk"
"${APKTOOL_COMMAND[@]}" d -f -r "$APK_PATH" -o "$DECODE_DIR"

mapfile -d '' -t XTS_CLASS_FILES < <(
    find "$DECODE_DIR" -type f -path "*/$XTS_CLASS_PATH" -print0
)

(( ${#XTS_CLASS_FILES[@]} == 1 )) ||
    fail "XtsApp 类数量异常：期望 1 个，实际 ${#XTS_CLASS_FILES[@]} 个"

mapfile -d '' -t SCREEN_STATUS_CLASS_FILES < <(
    find "$DECODE_DIR" -type f -path "*/$SCREEN_STATUS_CLASS_PATH" -print0
)

(( ${#SCREEN_STATUS_CLASS_FILES[@]} == 1 )) ||
    fail "MiRilHook 类数量异常：期望 1 个，实际 ${#SCREEN_STATUS_CLASS_FILES[@]} 个"

XTS_SMALI_FILE=${XTS_CLASS_FILES[0]}
SCREEN_STATUS_SMALI_FILE=${SCREEN_STATUS_CLASS_FILES[0]}

resolve_dex_entry() {
    local smali_file=$1
    local relative_smali_path=${smali_file#"$DECODE_DIR"/}
    local smali_root=${relative_smali_path%%/*}
    local dex_number

    case "$smali_root" in
        smali)
            printf '%s\n' 'classes.dex'
            ;;
        smali_classes[0-9]*)
            dex_number=${smali_root#smali_classes}
            [[ "$dex_number" =~ ^[0-9]+$ ]] || fail "无法识别 DEX 目录：$smali_root"
            printf 'classes%s.dex\n' "$dex_number"
            ;;
        *)
            fail "无法从目录识别目标 DEX：$smali_root"
            ;;
    esac
}

XTS_DEX_ENTRY=$(resolve_dex_entry "$XTS_SMALI_FILE")
SCREEN_STATUS_DEX_ENTRY=$(resolve_dex_entry "$SCREEN_STATUS_SMALI_FILE")
[[ "$XTS_DEX_ENTRY" == "$SCREEN_STATUS_DEX_ENTRY" ]] ||
    fail "XtsApp 与 MiRilHook 不在同一 DEX：$XTS_DEX_ENTRY / $SCREEN_STATUS_DEX_ENTRY"
DEX_ENTRY=$XTS_DEX_ENTRY

DEX_ENTRY_COUNT=$(archive_entry_count "$APK_PATH" "$DEX_ENTRY")
(( DEX_ENTRY_COUNT == 1 )) ||
    fail "原 APK 中 $DEX_ENTRY 数量异常：期望 1 个，实际 $DEX_ENTRY_COUNT 个"

XTS_SMALI_STATE=$(smali_patch_state "$XTS_SMALI_FILE" check xts) ||
    fail "XtsApp Smali 校验失败"
read -r VER_PATCHED XTS_PATCHED _ <<< "$XTS_SMALI_STATE"

SCREEN_STATUS_SMALI_STATE=$(
    smali_patch_state "$SCREEN_STATUS_SMALI_FILE" check screen_status
) || fail "MiRilHook Smali 校验失败"
read -r SCREEN_STATUS_PATCHED _ <<< "$SCREEN_STATUS_SMALI_STATE"

if (( VER_PATCHED == 1 && XTS_PATCHED == 1 && SCREEN_STATUS_PATCHED == 1 )); then
    "$ZIPALIGN_COMMAND" -c -P 16 4 "$APK_PATH" >/dev/null 2>&1 ||
        fail "三个目标方法已补丁，但 APK 未对齐，拒绝静默改写"
    log "SKIP：XTS 查询、支持判断与屏幕状态 OEM Hook 均已补丁，APK 对齐正常"
    exit 0
fi

log "修改 XtsApp 与 MiRilHook 的三个目标方法（目标 DEX：$DEX_ENTRY）"
XTS_SMALI_STATE=$(smali_patch_state "$XTS_SMALI_FILE" patch xts) ||
    fail "修改 XtsApp Smali 失败"
read -r VER_PATCHED XTS_PATCHED XTS_CHANGED_COUNT <<< "$XTS_SMALI_STATE"

SCREEN_STATUS_SMALI_STATE=$(
    smali_patch_state "$SCREEN_STATUS_SMALI_FILE" patch screen_status
) || fail "修改 MiRilHook Smali 失败"
read -r SCREEN_STATUS_PATCHED SCREEN_STATUS_CHANGED_COUNT <<< "$SCREEN_STATUS_SMALI_STATE"

CHANGED_COUNT=$((XTS_CHANGED_COUNT + SCREEN_STATUS_CHANGED_COUNT))
(( VER_PATCHED == 1 && XTS_PATCHED == 1 && SCREEN_STATUS_PATCHED == 1 && CHANGED_COUNT > 0 )) ||
    fail "修改后的 Smali 状态异常：ver=$VER_PATCHED xts=$XTS_PATCHED screen=$SCREEN_STATUS_PATCHED changed=$CHANGED_COUNT"

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
