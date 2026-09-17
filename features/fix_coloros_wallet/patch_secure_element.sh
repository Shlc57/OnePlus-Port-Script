#!/usr/bin/env bash
set -Eeuo pipefail

# ColorOS 钱包 eSE 访问白名单：固化进原包 com.android.se（SecureElement.apk）。
#
# 根因（2026-09-15 真机诊断）：FinShellWallet/TasWallet 通过 OMAPI 打开 eSE1 基础
# 通道读取 CPLC/卡数据时，被 AccessControlEnforcer 依据 eSE 上的 ARA-M 规则拒绝
# （"no APDU access allowed!" → "get cplc failed"）。底包 eSE 的 ARA-M 只放行
# 银联 UPTsmService 证书（53:6C:79:B9...）与 com.nxp.security，钱包证书不在其中，
# 且 ARA-M 自身仅允许银联证书更新，无法从镜像侧补规则。
#
# 修复：com.android.se 的 Terminal.isPrivilegedApplication 对持
# SECURE_ELEMENT_PRIVILEGED_OPERATION / ACCESS_ESE 权限的应用授予特权访问并完全
# 绕过 ARA-M。本补丁在该方法入口追加钱包包名白名单，命中即走同一条
# ChannelAccess.getPrivilegeAccess（全 ALLOWED）路径，等价于参考 LSP 方案的
# SecureElement 白名单 hook。钱包五件套为原签名系统应用，仅这些固定包名能命中。
#
# 幂等状态机：未补丁 → 插入白名单；已补丁 → 原地跳过；检测到异常结构拒绝修改。

PATCHER_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PORT_DIR=$(cd -- "$PATCHER_DIR/../.." && pwd -P)
APK_PATCHER="$PORT_DIR/tools/apk_patcher.sh"

log() { printf '[*] %s\n' "$*"; }
fail() { printf '[!] %s\n' "$*" >&2; exit 1; }
WORK_DIR=''
cleanup() {
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
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
# 本补丁修改的是 SecureElement.apk（system），与组合流程的 Settings 共享会话
# 归档不同，必须使用独立会话目录。
unset APK_PATCHER_SESSION_DIR
# shellcheck disable=SC1090
source "$APK_PATCHER"

(( $# == 1 )) || fail "用法：$0 <SecureElement.apk>"
APK_PATH=$1
[[ -f "$APK_PATH" && ! -L "$APK_PATH" ]] || fail "找不到 SecureElement.apk：$APK_PATH"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd -P)/$(basename -- "$APK_PATH")
APK_DIR=$(dirname -- "$APK_PATH")
WORK_DIR=$(mktemp -d "${SECURE_ELEMENT_PATCH_TMPDIR:-$APK_DIR}/.secure-element-patcher.XXXXXX")
SESSION_DIR="$WORK_DIR"
trap cleanup EXIT
apk_patcher_open "$SESSION_DIR" "$APK_PATH" apk || fail "无法打开 SecureElement.apk 会话"
apk_patcher_snapshot || fail "无法保存 SecureElement.apk 补丁快照"
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR=$SESSION_DECODE_DIR
CLASS_PATH='com/android/se/Terminal.smali'
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

METHOD_SIG='isPrivilegedApplication(Ljava/lang/String;)Z'
# 白名单包名即幂等标记：方法内命中全部包名字符串视为已补丁。
mapfile -t WHITELIST_PACKAGES < <(printf '%s\n' \
    'com.finshell.wallet' \
    'com.heytap.tas' \
    'com.heytap.htms')

# 统计目标方法体内指定字符串出现次数（幂等状态机依据）。
count_in_method() {
    local smali_file=$1 needle=$2

    awk -v method_sig="$METHOD_SIG" -v needle="$needle" '
        { lines[NR] = $0 }
        END {
            for (i = 1; i <= NR; i++) {
                if (lines[i] ~ /^[[:space:]]*\.method[[:space:]]/) {
                    in_method = (index(lines[i], method_sig) > 0)
                }
                if (in_method && index(lines[i], needle) > 0) count++
            }
            print count + 0
        }
    ' "$smali_file"
}

read -r METHOD_COUNT < <(awk -v method_sig="$METHOD_SIG" '
    /^[[:space:]]*\.method[[:space:]].*[[:space:]]/ && index($0, method_sig) > 0 { count++ }
    END { print count + 0 }
' "$SMALI_FILE")
(( METHOD_COUNT == 1 )) || fail "目标方法数量异常：期望 1 个，实际 $METHOD_COUNT 个"

total_hits=0
for pkg in "${WHITELIST_PACKAGES[@]}"; do
    hits=$(count_in_method "$SMALI_FILE" "$pkg")
    if (( hits > 1 )); then
        fail "白名单包名 $pkg 在目标方法中出现 $hits 次，结构异常，拒绝盲目修改"
    fi
    total_hits=$((total_hits + hits))
done

if (( total_hits == ${#WHITELIST_PACKAGES[@]} )); then
    log "SKIP：isPrivilegedApplication 已包含钱包 eSE 白名单"
    exit 0
fi
(( total_hits == 0 )) || fail "白名单标记不完整（$total_hits/${#WHITELIST_PACKAGES[@]}），拒绝修改"

log "修改 isPrivilegedApplication（目标 DEX：$DEX_ENTRY）"
awk -v method_sig="$METHOD_SIG" -v whitelist="${WHITELIST_PACKAGES[*]}" '
    BEGIN {
        n = split(whitelist, pkgs, " ")
        # 白名单检查块：命中任一包名跳到方法尾部授权块。
        check = "\t# ColorOS 钱包 eSE 白名单（移植固化）：命中包名直接授予特权访问，\n"
        check = check "\t# 绕过 ARA-M 规则缺失导致的 AccessControlException（真机 2026-09-15）。\n"
        for (i = 1; i <= n; i++) {
            check = check sprintf("\tconst-string v0, \"%s\"\n", pkgs[i])
            check = check "\tinvoke-virtual {v0, p1}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z\n"
            check = check "\tmove-result v0\n"
            check = check "\tif-nez v0, :cond_wallet_ese_grant\n"
        }
        grant = "\t:cond_wallet_ese_grant\n\tconst/4 p0, 0x1\n\treturn p0\n"
    }
    { lines[NR] = $0 }
    END {
        in_method = 0
        locals_inserted = 0
        grant_inserted = 0
        for (i = 1; i <= NR; i++) {
            line = lines[i]
            if (line ~ /^[[:space:]]*\.method[[:space:]]/) {
                in_method = (index(line, method_sig) > 0)
            }
            if (in_method && !locals_inserted && line ~ /^[[:space:]]*\.locals[[:space:]]+3[[:space:]]*$/) {
                printf "%s", check
                locals_inserted = 1
            }
            if (in_method && line ~ /^[[:space:]]*\.end method[[:space:]]*$/) {
                if (!locals_inserted) { status = 1; exit status }
                printf "%s", grant
                grant_inserted = 1
                in_method = 0
            }
            print line
        }
        if (!locals_inserted || !grant_inserted) exit 1
    }
' "$SMALI_FILE" > "$SMALI_FILE.new" || fail "修改目标 Smali 失败"
mv -- "$SMALI_FILE.new" "$SMALI_FILE"

for pkg in "${WHITELIST_PACKAGES[@]}"; do
    hits=$(count_in_method "$SMALI_FILE" "$pkg")
    (( hits == 1 )) || fail "修改后的 Smali 校验失败：$pkg 出现 $hits 次"
done
grep -q ':cond_wallet_ese_grant' "$SMALI_FILE" || fail "修改后的 Smali 缺少授权块标签"

apk_patcher_record_entry "$DEX_ENTRY" || fail "无法登记 SecureElement.apk 目标 DEX"
apk_patcher_finalize || fail "SecureElement.apk 最终回编译失败"
log "APPLY：补丁完成：$APK_PATH"
