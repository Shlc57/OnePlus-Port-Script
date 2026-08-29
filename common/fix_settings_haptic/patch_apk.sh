#!/usr/bin/env bash
set -Eeuo pipefail

PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PORT_DIR=$(cd -- "$PATCHER_DIR/../.." && pwd -P)
APK_PATCHER="$PORT_DIR/common/apk_patcher.sh"

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
CLASS_PATH='com/android/settings/utils/SettingsFeatures.smali'
METHOD_NAME='isSupportSettingsHaptic(Landroid/content/Context;)Z'
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
read -r METHOD_COUNT ZERO_COUNT ONE_COUNT < <(haptic_method_state "$SMALI_FILE")
(( METHOD_COUNT == 1 )) || fail "目标方法数量异常：期望 1 个，实际 $METHOD_COUNT 个"
if (( ZERO_COUNT == 0 && ONE_COUNT == 1 )); then log "SKIP：$METHOD_NAME 已补丁"; exit 0; fi
(( ZERO_COUNT == 1 && ONE_COUNT == 0 )) || fail "目标指令结构异常：0x0=$ZERO_COUNT，0x1=$ONE_COUNT，拒绝盲目修改"
log "修改 $METHOD_NAME（目标 DEX：$DEX_ENTRY）"
awk '
    function normalize_instruction(line) {
        sub(/[[:space:]]*#.*/, "", line)
        sub(/^[[:space:]]+/, "", line)
        sub(/[[:space:]]+$/, "", line)
        if (line == "" || substr(line, 1, 1) == "." || substr(line, 1, 1) == ":") return ""
        return line
    }
    /^[[:space:]]*\.method[[:space:]].*isSupportSettingsHaptic\(Landroid\/content\/Context;\)Z[[:space:]]*$/ { in_method=1; instruction_count=0 }
    in_method {
        normalized=normalize_instruction($0)
        if (normalized != "") {
            instruction_count++
            if (instruction_count == 1 && normalized ~ /^const\/4[[:space:]]+v0,[[:space:]]+0x0$/) { sub(/0x0/, "0x1"); patched=1 }
        }
    }
    { print }
    in_method && /^[[:space:]]*\.end method[[:space:]]*$/ { in_method=0 }
    END { if (!patched) exit 1 }
' "$SMALI_FILE" > "$SMALI_FILE.new" || fail "修改目标 Smali 失败"
mv -- "$SMALI_FILE.new" "$SMALI_FILE"
read -r METHOD_COUNT ZERO_COUNT ONE_COUNT < <(haptic_method_state "$SMALI_FILE")
(( METHOD_COUNT == 1 && ZERO_COUNT == 0 && ONE_COUNT == 1 )) || fail "修改后的 Smali 校验失败"


apk_patcher_record_entry "$DEX_ENTRY" || fail "无法登记 Settings.apk 目标 DEX"
if (( SESSION_MODE == 1 )); then
    log "已登记 Settings.apk 的 $DEX_ENTRY 修改，等待统一回编译"
else
    apk_patcher_finalize || fail "Settings.apk 最终回编译失败"
    log "APPLY：补丁完成：$APK_PATH"
fi
