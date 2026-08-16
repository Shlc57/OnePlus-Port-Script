#!/usr/bin/env bash
set -Eeuo pipefail

CLASS_PATH='com/android/settings/utils/SettingsFeatures.smali'
METHOD_NAME='isSupportSettingsHaptic(Landroid/content/Context;)Z'
PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
SIGNING_BLOCK_TOOL="$PATCHER_DIR/apk_signing_block.py"

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

method_state() {
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

validate_and_install_apk() {
    local excluded_entry=$1
    local content_before=$2
    local content_after=$3
    local expected_entry_file=${4:-}

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

    REPLACEMENT_PATH=$(mktemp "$APK_DIR/.Settings.apk.patch.XXXXXX")
    rm -f -- "$REPLACEMENT_PATH"
    cp -a -- "$PATCHED_APK" "$REPLACEMENT_PATH"
    mv -fT -- "$REPLACEMENT_PATH" "$APK_PATH"
    REPLACEMENT_PATH=''

    log "APPLY：补丁完成：$APK_PATH"
    log "已原样保留 Signing Block 与 META-INF 证书材料，但 DEX 修改后 v1/v2/v3 内容完整性签名必然失效"
    log "本产物仅适用于已确认系统扫描绕过完整性校验、仍需保留原证书身份的 ROM；不能作为普通 APK 安装"
}

(( $# == 1 )) || fail "用法：$0 <Settings.apk>"
APK_PATH=$1

for command_name in awk basename cmp cp dirname find mkdir mktemp mv python3 rm sha256sum sort tail unzip zip; do
    require_command "$command_name"
done
resolve_apktool
resolve_zipalign
[[ -r "$SIGNING_BLOCK_TOOL" ]] || fail "找不到 Signing Block 工具：$SIGNING_BLOCK_TOOL"

[[ -f "$APK_PATH" ]] || fail "找不到 Settings.apk：$APK_PATH"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd)/$(basename -- "$APK_PATH")
APK_DIR=$(dirname -- "$APK_PATH")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/fix-settings-haptic.XXXXXX")
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR="$WORK_DIR/decoded"
REBUILT_APK="$WORK_DIR/rebuilt.apk"
DEX_DIR="$WORK_DIR/dex"
PATCHED_APK="$WORK_DIR/Settings.apk.patched"
ALIGNED_APK="$WORK_DIR/Settings.apk.aligned"
ARCHIVE_ENTRIES_BEFORE="$WORK_DIR/archive-entries.before"
ARCHIVE_ENTRIES_AFTER="$WORK_DIR/archive-entries.after"
NON_TARGET_CONTENT_BEFORE="$WORK_DIR/non-target-content.before"
NON_TARGET_CONTENT_AFTER="$WORK_DIR/non-target-content.after"
ALL_CONTENT_BEFORE="$WORK_DIR/all-content.before"
ALL_CONTENT_AFTER="$WORK_DIR/all-content.after"
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

log "反编译 Settings.apk"
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

read -r METHOD_COUNT ZERO_COUNT ONE_COUNT < <(method_state "$SMALI_FILE")
(( METHOD_COUNT == 1 )) ||
    fail "目标方法数量异常：期望 1 个，实际 $METHOD_COUNT 个"

if (( ZERO_COUNT == 0 && ONE_COUNT == 1 )); then
    if "$ZIPALIGN_COMMAND" -c -P 16 4 "$APK_PATH" >/dev/null 2>&1; then
        log "SKIP：$METHOD_NAME 已经返回 const/4 v0, 0x1，且 APK 对齐正常"
        exit 0
    fi

    log "$METHOD_NAME 已经返回 const/4 v0, 0x1，但 APK 未对齐；仅修复归档对齐"
    archive_content_snapshot "$APK_PATH" "" "$ALL_CONTENT_BEFORE"
    "$ZIPALIGN_COMMAND" -f -P 16 4 "$APK_PATH" "$ALIGNED_APK" ||
        fail "zipalign 对齐失败"
    mv -- "$ALIGNED_APK" "$PATCHED_APK"
    validate_and_install_apk "" "$ALL_CONTENT_BEFORE" "$ALL_CONTENT_AFTER"
    exit 0
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

read -r METHOD_COUNT ZERO_COUNT ONE_COUNT < <(method_state "$SMALI_FILE")
(( METHOD_COUNT == 1 && ZERO_COUNT == 0 && ONE_COUNT == 1 )) ||
    fail "修改后的 Smali 校验失败"

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
