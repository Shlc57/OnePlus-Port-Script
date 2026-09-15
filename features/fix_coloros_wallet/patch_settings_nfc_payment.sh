#!/usr/bin/env bash
set -Eeuo pipefail

# MIUI Settings 感应式支付页修复：补齐 AOSP 旧类名 com.android.settings.nfc.PaymentSettings。
#
# 根因（2026-09-15 真机诊断）：ColorOS 钱包通过 android.settings.NFC_PAYMENT_SETTINGS
# 跳转系统"感应式支付"页，MIUI Settings 的 Settings$PaymentSettingsActivity 别名
# meta-data 仍指向 AOSP 类名 com.android.settings.nfc.PaymentSettings，但 MIUI 已把
# 实现改名为 com.android.settings.nfc.DefaultPaymentSettings，旧类名不存在导致
# Fragment$InstantiationException / ClassNotFoundException，页面只剩标题没有内容。
#
# 修复：在 Settings.apk 内新增一个空壳子类 PaymentSettings extends
# DefaultPaymentSettings，让别名 meta-data 恢复可用。Settings.apk 位于原包
# system_ext，无签名约束。
#
# 幂等状态机：类已存在 → 原地跳过；目标超类不存在 → 拒绝修改。

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
    WORK_DIR=$(mktemp -d "${SETTINGS_NFC_PATCH_TMPDIR:-$APK_DIR}/.settings-nfc-payment-patcher.XXXXXX")
    SESSION_DIR="$WORK_DIR"
    trap cleanup EXIT
fi
apk_patcher_open "$SESSION_DIR" "$APK_PATH" apk || fail "无法打开 Settings.apk 会话"
apk_patcher_snapshot || fail "无法保存 Settings.apk 补丁快照"
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR=$SESSION_DECODE_DIR

# 在全部 smali 目录中定位 DefaultPaymentSettings 实现类所在 DEX。
mapfile -d '' -t SUPER_FILES < <(find "$DECODE_DIR" -type f -path \
    '*/com/android/settings/nfc/DefaultPaymentSettings.smali' -print0)
(( ${#SUPER_FILES[@]} == 1 )) || fail "DefaultPaymentSettings 类数量异常：期望 1 个，实际 ${#SUPER_FILES[@]} 个"
SUPER_FILE=${SUPER_FILES[0]}
RELATIVE_SUPER_PATH=${SUPER_FILE#"$DECODE_DIR"/}
SMALI_ROOT=${RELATIVE_SUPER_PATH%%/*}
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

# 超类必须有可用默认构造函数。
grep -q '\.method public constructor <init>()V' "$SUPER_FILE" ||
    fail "DefaultPaymentSettings 缺少默认构造函数，拒绝生成子类"

TARGET_SMALI_DIR="$DECODE_DIR/$SMALI_ROOT/com/android/settings/nfc"
TARGET_CLASS_FILE="$TARGET_SMALI_DIR/PaymentSettings.smali"
if [[ -e "$TARGET_CLASS_FILE" ]]; then
    log "SKIP：com.android.settings.nfc.PaymentSettings 已存在"
    exit 0
fi

log "新增 PaymentSettings 空壳类（目标 DEX：$DEX_ENTRY）"
cat > "$TARGET_CLASS_FILE" <<'EOF'
.class public Lcom/android/settings/nfc/PaymentSettings;
.super Lcom/android/settings/nfc/DefaultPaymentSettings;
.source "PaymentSettings.java"


# direct methods
.method public constructor <init>()V
    .locals 0

    invoke-direct {p0}, Lcom/android/settings/nfc/DefaultPaymentSettings;-><init>()V

    return-void
.end method
EOF

grep -q 'Lcom/android/settings/nfc/PaymentSettings;' "$TARGET_CLASS_FILE" ||
    fail "生成的 PaymentSettings.smali 校验失败"

apk_patcher_record_entry "$DEX_ENTRY" || fail "无法登记 Settings.apk 目标 DEX"
if (( SESSION_MODE == 1 )); then
    log "已登记 Settings.apk 的 $DEX_ENTRY 修改，等待统一回编译"
else
    apk_patcher_finalize || fail "Settings.apk 最终回编译失败"
    log "APPLY：补丁完成：$APK_PATH"
fi
