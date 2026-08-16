#!/usr/bin/env bash
set -Eeuo pipefail

CLASS_PATH='com/android/phone/XtsApp.smali'
PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PORT_ROOT=$(cd -- "$PATCHER_DIR/../.." && pwd)
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
    local apk=$1
    local output=$2

    LC_ALL=C unzip -Z1 "$apk" | LC_ALL=C sort > "$output"
}

archive_content_snapshot() {
    local apk=$1
    local excluded_entry=$2
    local output=$3

    python3 - "$apk" "$excluded_entry" "$output" <<'PY'
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
    local apk=$1
    local output=$2
    local entries_file=$3
    local entry digest

    LC_ALL=C unzip -Z1 "$apk" |
        awk 'toupper($0) ~ /^META-INF\/.*\.(MF|SF|RSA|DSA|EC)$/ { print }' |
        LC_ALL=C sort > "$entries_file"

    : > "$output"
    while IFS= read -r entry; do
        [[ -n "$entry" ]] || continue
        digest=$(unzip -p "$apk" "$entry" | sha256sum | awk '{ print $1 }')
        printf '%s\t%s\n' "$digest" "$entry" >> "$output"
    done < "$entries_file"
}

smali_patch_state() {
    local smali_file=$1
    local mode=$2

    python3 - "$smali_file" "$mode" <<'PY'
import re
import sys
from pathlib import Path


class PatchError(Exception):
    pass


path = Path(sys.argv[1])
mode = sys.argv[2]
if mode not in {"check", "patch"}:
    raise SystemExit("[!] 无效的 Smali 操作模式")

specs = {
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
    },
}


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

        if key == "ver":
            patched = bool(instructions and instructions[0] == "return-void")
        else:
            patched = bool(
                len(instructions) >= 2
                and re.fullmatch(r"const/4\s+v0,\s+0x0", instructions[0])
                and re.fullmatch(r"return\s+v0", instructions[1])
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

    print("{} {} {}".format(int(states["ver"]), int(states["xts"]), changed))
except (OSError, PatchError) as error:
    print("[!] {}".format(error), file=sys.stderr)
    raise SystemExit(1)
PY
}

validate_and_install_apk() {
    local excluded_entry=$1
    local content_before=$2
    local content_after=$3
    local expected_entry_file=$4

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

    archive_entries_snapshot "$PATCHED_APK" "$ARCHIVE_ENTRIES_AFTER"
    cmp -s "$ARCHIVE_ENTRIES_BEFORE" "$ARCHIVE_ENTRIES_AFTER" ||
        fail "更新后 APK 的归档条目列表发生变化"
    archive_content_snapshot "$PATCHED_APK" "$excluded_entry" "$content_after"
    cmp -s "$content_before" "$content_after" ||
        fail "更新后存在预期目标之外的条目内容变化"

    signature_snapshot "$PATCHED_APK" "$SIGNATURES_AFTER" "$SIGNATURE_ENTRIES_AFTER"
    cmp -s "$SIGNATURE_ENTRIES_BEFORE" "$SIGNATURE_ENTRIES_AFTER" ||
        fail "更新后签名条目列表发生变化"
    cmp -s "$SIGNATURES_BEFORE" "$SIGNATURES_AFTER" ||
        fail "更新后签名条目内容发生变化"

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

for command_name in awk basename cmp cp dirname find mkdir mktemp mv python3 rm sha256sum sort tail unzip zip; do
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

log "记录原 APK 的归档条目和签名数据"
archive_entries_snapshot "$APK_PATH" "$ARCHIVE_ENTRIES_BEFORE"
signature_snapshot "$APK_PATH" "$SIGNATURES_BEFORE" "$SIGNATURE_ENTRIES_BEFORE"
SIGNING_BLOCK_PAIR_IDS=$(
    python3 "$SIGNING_BLOCK_TOOL" extract "$APK_PATH" "$SIGNING_BLOCK_BEFORE"
)
log "已保存原 APK Signing Block Pair IDs：$SIGNING_BLOCK_PAIR_IDS"

log "反编译 TeleService.apk"
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

DEX_ENTRY_COUNT=$(awk -v entry="$DEX_ENTRY" '$0 == entry { count++ } END { print count + 0 }' "$ARCHIVE_ENTRIES_BEFORE")
(( DEX_ENTRY_COUNT == 1 )) ||
    fail "原 APK 中 $DEX_ENTRY 数量异常：期望 1 个，实际 $DEX_ENTRY_COUNT 个"
archive_content_snapshot "$APK_PATH" "$DEX_ENTRY" "$NON_TARGET_CONTENT_BEFORE"

SMALI_STATE=$(smali_patch_state "$SMALI_FILE" check) || fail "目标 Smali 校验失败"
read -r VER_PATCHED XTS_PATCHED _ <<< "$SMALI_STATE"

if (( VER_PATCHED == 1 && XTS_PATCHED == 1 )); then
    "$ZIPALIGN_COMMAND" -c -P 16 4 "$APK_PATH" >/dev/null 2>&1 ||
        fail "两个目标方法已补丁，但 APK 未对齐，拒绝静默改写"
    log "SKIP：XTS modem 查询与支持判断均已补丁，APK 对齐正常"
    exit 0
fi

log "修改 XtsApp 两个目标方法（目标 DEX：$DEX_ENTRY）"
SMALI_STATE=$(smali_patch_state "$SMALI_FILE" patch) || fail "修改目标 Smali 失败"
read -r VER_PATCHED XTS_PATCHED CHANGED_COUNT <<< "$SMALI_STATE"
(( VER_PATCHED == 1 && XTS_PATCHED == 1 && CHANGED_COUNT > 0 )) ||
    fail "修改后的 Smali 状态异常：ver=$VER_PATCHED xts=$XTS_PATCHED changed=$CHANGED_COUNT"

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
    "$NON_TARGET_CONTENT_BEFORE" \
    "$NON_TARGET_CONTENT_AFTER" \
    "$DEX_DIR/$DEX_ENTRY"
