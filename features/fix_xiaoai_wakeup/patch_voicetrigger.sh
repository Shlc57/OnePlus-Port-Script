#!/usr/bin/env bash
set -Eeuo pipefail

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
# 本补丁修改的是 VoiceTrigger.apk（product），与组合流程的 Settings 共享会话
# 归档不同，必须使用独立会话目录。
unset APK_PATCHER_SESSION_DIR
# shellcheck disable=SC1090
source "$APK_PATCHER"

(( $# == 1 )) || fail "用法：$0 <VoiceTrigger.apk>"
APK_PATH=$1
[[ -f "$APK_PATH" && ! -L "$APK_PATH" ]] || fail "找不到 VoiceTrigger.apk：$APK_PATH"
APK_PATH=$(cd -- "$(dirname -- "$APK_PATH")" && pwd -P)/$(basename -- "$APK_PATH")

# CPU FlexKws 前端（XIAOAI_CPU_KWS）：ADSP 不接受小米 CUSTOM1 模型的组合上，
# 改用原包自带的 CPU 唤醒栈。它和互联兜底共用同一次解包会话与 classes2.dex。
# 三个节奏常量由机型参数经 apply.sh 注入，默认值等于 Ace 6T 刷机验证过的取值。
cpu_kws="${XIAOAI_CPU_KWS:-false}"
if [[ "$cpu_kws" != true && "$cpu_kws" != false ]]; then
    fail "XIAOAI_CPU_KWS 只接受 true/false：$cpu_kws"
fi
cpu_kws_hold_ms="${XIAOAI_CPU_KWS_HOLD_MS:-5000}"
cpu_kws_gap_ms="${XIAOAI_CPU_KWS_GAP_MS:-1500}"
cpu_kws_window_sec="${XIAOAI_CPU_KWS_WINDOW_SEC:-6}"
for cadence_name in cpu_kws_hold_ms cpu_kws_gap_ms cpu_kws_window_sec; do
    cadence_value="${!cadence_name}"
    [[ "$cadence_value" =~ ^(0|[1-9][0-9]*)$ ]] ||
        fail "$cadence_name 必须是十进制非负整数（不带前导 0）：$cadence_value"
done
CPU_KWS_EDITS="$PATCHER_DIR/cpu_kws_edits.py"
CPU_KWS_CLASS="$PATCHER_DIR/config/PortCpuKws.smali"
if [[ "$cpu_kws" == true ]]; then
    [[ -f "$CPU_KWS_EDITS" && ! -L "$CPU_KWS_EDITS" ]] ||
        fail "缺少 CPU KWS 改法脚本：$CPU_KWS_EDITS"
    [[ -f "$CPU_KWS_CLASS" && ! -L "$CPU_KWS_CLASS" ]] ||
        fail "缺少 CPU KWS 前端资源：$CPU_KWS_CLASS"
fi
# PortCpuKws 资源由 cpu_kws_edits.py 从这份原文安装并写机型让麦时长，不在这里 cp。
CPU_KWS_ARGS=(--hold-ms "$cpu_kws_hold_ms" --gap-ms "$cpu_kws_gap_ms"
    --window-sec "$cpu_kws_window_sec" --class-source "$CPU_KWS_CLASS")

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/.voicetrigger-apk-patcher.XXXXXX")
trap cleanup EXIT
apk_patcher_open "$WORK_DIR" "$APK_PATH" apk || fail "无法打开 VoiceTrigger.apk 会话"
apk_patcher_snapshot || fail "无法保存 VoiceTrigger.apk 补丁快照"
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR=$SESSION_DECODE_DIR

voicetrigger_edits_state() {
    local mode=${1:-check}
    python3 - "$DECODE_DIR" "$mode" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path


decode_dir = Path(sys.argv[1])
mode = sys.argv[2]
if mode not in {"check", "patch"}:
    raise SystemExit(f"不支持的操作模式：{mode}")

infra_smali = (decode_dir / "smali_classes2" / "com" / "xiaomi" / "continuity"
              / "infra" / "ServiceConnector$Impl.smali")


def read(path):
    return path.read_text(encoding="utf-8")


def write_file(path, updated, description):
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
            temporary.write(updated)
            temporary_name = temporary.name
        try:
            os.chmod(temporary_name, file_mode)
            os.replace(temporary_name, path)
        except Exception:
            os.unlink(temporary_name)
            raise
    except OSError as error:
        raise SystemExit(f"写入{description}失败：{path}：{error}")


# 修改：给 SDK>=29 的 Context.bindService 直调加 SecurityException 兜底。
# 小米互联服务预置版缺 ContinuityServiceManagerService 组件时，这行直调抛未捕获
# SecurityException，由 continuity-service-manager-connector 线程杀死 VoiceTrigger 进程。
# 反射路径（SDK<29）自带 try，不需要兜底。
infra_bind_method = (
    r"^\.method public bindService\(Landroid/content/ServiceConnection;\)Z"
    r"[ \t]*\n.*?^\.end method[ \t]*$"
)
bind_call = re.compile(
    r"(?P<indent>[ \t]*)(?P<call>invoke-virtual \{[^}]*\}, Landroid/content/Context;"
    r"->bindService\(Landroid/content/Intent;ILjava/util/concurrent/Executor;"
    r"Landroid/content/ServiceConnection;\)Z)\n\n"
    r"(?P<moved>[ \t]*move-result (?P<res>[A-Za-z0-9_.$-]+)\n)\n"
    r"(?P<ret>[ \t]*return (?P=res)\n)"
)
if not infra_smali.is_file():
    bind_state = "absent"
else:
    infra_text = read(infra_smali)
    infra_matches = list(re.finditer(infra_bind_method, infra_text, re.M | re.S))
    if len(infra_matches) != 1:
        raise SystemExit(
            f"ServiceConnector$Impl.bindService 方法块数量应为 1，实际 {len(infra_matches)}，"
            f"VoiceTrigger 版本不受支持：{infra_smali}"
        )
    bind_block = infra_matches[0].group(0)
    if ".catch Ljava/lang/SecurityException;" in bind_block:
        bind_state = "patched"
    elif bind_call.search(bind_block):
        bind_state = "original"
    else:
        bind_state = "absent"

states = {
    "bind_guard": bind_state,
}
# absent 表示该项在本版本不存在，等同已完成，不能归入 unknown 也不会阻碍幂等判定。
satisfied = {"patched", "absent"}
pending = {"original", "absent"}
if mode == "check":
    if all(state in satisfied for state in states.values()):
        print("patched")
    elif all(state in pending for state in states.values()):
        print("original")
    elif any(state == "unknown" for state in states.values()):
        print("unknown")
    else:
        print("partial")
    raise SystemExit(0)

if any(state == "unknown" for state in states.values()):
    raise SystemExit(
        "VoiceTrigger 目标方法指令结构不是受支持的状态，拒绝盲目修改："
        + " ".join(f"{name}={state}" for name, state in states.items())
    )

# 幂等处理：original 植入，patched/absent 跳过。
if states["bind_guard"] == "original":
    def wrap_bind(match):
        indent = match.group("indent")
        res = match.group("res")
        return (
            f"{indent}:try_start_portai\n"
            f"{indent}{match.group('call')}\n\n"
            f"{match.group('moved')}"
            f"{indent}:try_end_portai\n"
            f"{indent}.catch Ljava/lang/SecurityException; "
            "{:try_start_portai .. :try_end_portai} :catch_portai\n\n"
            f"{match.group('ret')}\n"
            f"{indent}:catch_portai\n"
            f"{indent}const/4 {res}, 0x0\n\n"
            f"{indent}return {res}\n"
        )

    patched_block = bind_call.sub(wrap_bind, bind_block, count=1)
    if patched_block == bind_block:
        raise SystemExit("Context.bindService 直调结构不符合预期，无法植入 SecurityException 兜底")
    write_file(infra_smali, infra_text.replace(bind_block, patched_block, 1), "continuity 绑定兜底")

print("patched ok")
PY
}

STATE=$(voicetrigger_edits_state check)
KWS_STATE=disabled
if [[ "$cpu_kws" == true ]]; then
    KWS_STATE=$(python3 "$CPU_KWS_EDITS" check "$DECODE_DIR" "${CPU_KWS_ARGS[@]}") ||
        fail "CPU KWS 植入点状态检查失败"
fi
case "$KWS_STATE" in
    disabled|original|partial|patched) ;;
    *)
        fail "CPU KWS 植入点指令结构与受支持版本不一致，拒绝盲目修改：state=$KWS_STATE"
        ;;
esac
if [[ "$STATE" == patched && "$KWS_STATE" != original && "$KWS_STATE" != partial ]]; then
    log "SKIP：VoiceTrigger 小爱唤醒修复已植入"
    exit 0
fi
case "$STATE" in
    patched|original|partial) ;;
    *)
        fail "VoiceTrigger 目标方法结构与当前支持版本不一致，拒绝盲目修改：state=$STATE"
        ;;
esac

# 所有保留的植入点（互联兜底与 CPU FlexKws 前端）都在 classes2.dex。
DEX_ENTRY='classes2.dex'
[[ "$(apk_patcher_entry_count "$APK_PATH" "$DEX_ENTRY")" == 1 ]] ||
    fail "原 APK 中 $DEX_ENTRY 数量异常"

log "修改 VoiceTrigger 唤醒链路（目标 DEX：$DEX_ENTRY，state=$STATE）"
PATCH_RESULT=$(voicetrigger_edits_state patch) || fail "修改 VoiceTrigger Smali 失败"
[[ "$PATCH_RESULT" == 'patched ok' ]] || fail "VoiceTrigger Smali 未产生预期修改：$PATCH_RESULT"
[[ "$(voicetrigger_edits_state check)" == 'patched' ]] || fail "修改后的 VoiceTrigger Smali 校验失败"

apk_patcher_record_entry "$DEX_ENTRY" || fail "无法登记 VoiceTrigger.apk 目标 DEX"

if [[ "$cpu_kws" == true && "$KWS_STATE" != patched ]]; then
    log "植入 CPU FlexKws 前端（state=$KWS_STATE，让麦 ${cpu_kws_hold_ms}ms/间隔 ${cpu_kws_gap_ms}ms/窗口 ${cpu_kws_window_sec}s）"
    KWS_RESULT=$(python3 "$CPU_KWS_EDITS" patch "$DECODE_DIR" "${CPU_KWS_ARGS[@]}") ||
        fail "CPU KWS Smali 修改失败"
    case "$KWS_RESULT" in
        'patched ok'|'already patched') ;;
        *) fail "CPU KWS Smali 未产生预期修改：$KWS_RESULT" ;;
    esac
    [[ "$(python3 "$CPU_KWS_EDITS" check "$DECODE_DIR" "${CPU_KWS_ARGS[@]}")" == patched ]] ||
        fail "修改后的 CPU KWS Smali 校验失败"
    apk_patcher_record_entry "$DEX_ENTRY" || fail "无法登记 CPU KWS 目标 DEX"
fi

apk_patcher_finalize || fail "VoiceTrigger.apk 最终回编译失败"
log "APPLY：补丁完成：$APK_PATH"
