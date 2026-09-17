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
WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/.voicetrigger-apk-patcher.XXXXXX")
trap cleanup EXIT
apk_patcher_open "$WORK_DIR" "$APK_PATH" apk || fail "无法打开 VoiceTrigger.apk 会话"
apk_patcher_snapshot || fail "无法保存 VoiceTrigger.apk 补丁快照"
trap rollback_on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

DECODE_DIR=$SESSION_DECODE_DIR
WAKEUP_DIR_REL='smali_classes2/com/miui/voicetrigger/wakeup'

smali_dex_entry() {
    local relative_path=${1#"$DECODE_DIR"/}
    local smali_root=${relative_path%%/*}
    case "$smali_root" in
        smali) printf 'classes.dex' ;;
        smali_classes[0-9]*)
            local number=${smali_root#smali_classes}
            [[ "$number" =~ ^[0-9]+$ ]] || fail "无法识别 DEX 目录：$smali_root"
            printf 'classes%s.dex' "$number"
            ;;
        *) fail "无法从目录识别目标 DEX：$smali_root" ;;
    esac
}

voicetrigger_edits_state() {
    local mode=${1:-check}
    python3 - "$DECODE_DIR" "$PATCHER_DIR/config/PortWakeupHooks.smali" "$mode" <<'PY'
import os
import re
import stat
import sys
import tempfile
from pathlib import Path


decode_dir = Path(sys.argv[1])
helper_source = Path(sys.argv[2]).read_text(encoding="utf-8")
mode = sys.argv[3]
if mode not in {"check", "patch"}:
    raise SystemExit(f"不支持的操作模式：{mode}")

wakeup_dir = decode_dir / "smali_classes2" / "com" / "miui" / "voicetrigger" / "wakeup"
r_smali = wakeup_dir / "r.smali"
s_smali = wakeup_dir / "s.smali"
h_smali = decode_dir / "smali_classes2" / "v0" / "h.smali"
helper_smali = wakeup_dir / "PortWakeupHooks.smali"

for path in (r_smali, s_smali, h_smali):
    if not path.is_file():
        raise SystemExit(f"目标类缺失，VoiceTrigger 版本不受支持：{path}")


def method_block(text, pattern, path, name):
    matches = list(re.finditer(pattern, text, re.M | re.S))
    if len(matches) != 1:
        raise SystemExit(
            f"{name} 方法块数量应为 1，实际 {len(matches)}，"
            f"VoiceTrigger 版本不受支持：{path}"
        )
    return matches


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


r_method = (
    r"^\.method[^\n]*\bc\(\)\[Landroid/hardware/soundtrigger/SoundTrigger"
    r"\$KeyphraseRecognitionExtra;[ \t]*\n.*?^\.end method[ \t]*$"
)
r_e_method = (
    r"^\.method[^\n]*\be\(\)Landroid/hardware/soundtrigger/SoundTrigger"
    r"\$RecognitionConfig;[ \t]*\n.*?^\.end method[ \t]*$"
)
s_e_method = (
    r"^\.method public e\(Lcom/miui/voicetrigger/wakeup/w;\)V"
    r"[ \t]*\n.*?^\.end method[ \t]*$"
)
h_k_method = (
    r"^\.method public static k\(Landroid/content/Context;\)V"
    r"[ \t]*\n.*?^\.end method[ \t]*$"
)

r_text = read(r_smali)
s_text = read(s_smali)
h_text = read(h_smali)

# 修改 1：r.c() DSP L1 上报置信度 0x45(69) -> 0x23(35)
r_c_match = method_block(r_text, r_method, r_smali, "r.c()")[0]
r_c_block = r_c_match.group(0)
r_c_original = r_c_block.count("const/16 v4, 0x45") == 1
r_c_patched = r_c_block.count("const/16 v4, 0x23") == 1 and not r_c_original

# 修改 2：r.e() 空 data -> LAB 前视缓冲 20 字节
r_e_match = method_block(r_text, r_e_method, r_smali, "r.e()")[0]
r_e_block = r_e_match.group(0)
r_e_helper = "Lcom/miui/voicetrigger/wakeup/PortWakeupHooks;->buildLabData()[B"
lab_anchor = re.compile(
    r"const/4 v2, 0x0(\s+)const/4 v3, 0x1(\s+)const/4 v4, 0x0(\s+)"
    r"invoke-direct \{v0, v3, v4, v1, v2\}, "
    r"Landroid/hardware/soundtrigger/SoundTrigger\$RecognitionConfig;-><init>"
    r"\(ZZ\[Landroid/hardware/soundtrigger/SoundTrigger"
    r"\$KeyphraseRecognitionExtra;\[B\)V"
)
# DEX 校验禁止在 new-instance 与 invoke-direct <init> 之间执行 invoke
# （未初始化引用存活期），buildLabData 调用必须位于 new-instance 之前。
ni_line = "    new-instance v0, Landroid/hardware/soundtrigger/SoundTrigger$RecognitionConfig;\n\n"
inv_block = (
    f"    invoke-static {{}}, {r_e_helper}\n\n    move-result-object v2\n\n"
)
has_invoke = r_e_helper in r_e_block
ni_idx = r_e_block.find(ni_line.strip())
inv_idx = r_e_block.find("invoke-static {}, " + r_e_helper)
if not has_invoke:
    r_e_state = "original" if lab_anchor.search(r_e_block) else "unknown"
elif 0 <= inv_idx < ni_idx:
    r_e_state = "patched"
elif inv_idx > ni_idx:
    r_e_state = "v1"  # 历史坏版：invoke 位于 new-instance 之后，触发 VerifyError
else:
    r_e_state = "unknown"

# 修改 3：s.e(w) XATX/UDK 命令下绕过声纹门（关键词门保留）
s_e_match = method_block(s_text, s_e_method, s_smali, "s.e(w)")[0]
s_e_block = s_e_match.group(0)
# 状态标记不能依赖 baksmali 标签名（重新解码时标签会被重命名），
# 只能依赖字符串常量、寄存器名与指令序列等跨解码稳定结构。
vp_invoke = "invoke-virtual {p1}, Lcom/miui/voicetrigger/wakeup/w;->l()Z"
vp_gate = re.compile(
    re.escape(vp_invoke) + r"\n\n    move-result v0\n\n    if-eqz v0, :[A-Za-z0-9_.$-]+"
)
vp_bypass = (
    vp_invoke + "\n\n"
    "    move-result v0\n\n"
    "    iget-object v1, p0, Lcom/miui/voicetrigger/wakeup/s;->b:Ljava/lang/String;\n\n"
    "    if-eqz v1, :portai_vp_orig\n\n"
    '    const-string v2, "XATX"\n\n'
    "    invoke-virtual {v1, v2}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z\n\n"
    "    move-result v2\n\n"
    "    if-nez v2, :portai_vp_pass\n\n"
    '    const-string v2, "UDK"\n\n'
    "    invoke-virtual {v1, v2}, Ljava/lang/String;->equals(Ljava/lang/Object;)Z\n\n"
    "    move-result v2\n\n"
    "    if-eqz v2, :portai_vp_orig\n\n"
    "    :portai_vp_pass\n"
    "    const/4 v0, 0x1\n\n"
    "    :portai_vp_orig\n"
)
s_e_original = (
    len(vp_gate.findall(s_e_block)) == 1
    and 'const-string v2, "XATX"' not in s_e_block
    and 'const-string v2, "UDK"' not in s_e_block
)
s_e_patched = (
    s_e_block.count("Ljava/lang/String;->equals(Ljava/lang/Object;)Z") == 2
    and s_e_block.count('const-string v2, "XATX"') == 1
    and s_e_block.count('const-string v2, "UDK"') == 1
    and s_e_block.count("if-nez v2,") == 1
    and len(vp_gate.findall(s_e_block)) == 0
)

# 修改 4：v0/h.k() DSP 回调 wake lock 800ms -> 7000ms
# 宽常量寄存器随编译版本漂移（v0/v1 或 v2/v3），状态判定与替换都按实际寄存器处理。
h_k_match = method_block(h_text, h_k_method, h_smali, "h.k(Context)")[0]
h_k_block = h_k_match.group(0)
h_k_duration = re.compile(r"const-wide/16 (v\d+), 0x320\b")
h_k_original = len(h_k_duration.findall(h_k_block)) == 1
h_k_patched = (
    len(re.findall(r"const-wide/16 v\d+, 0x1b58\b", h_k_block)) == 1
    and not h_k_original
)

helper_present = helper_smali.is_file()
helper_methods = ("buildLabData", "putIntLE", "getIntProp", "clampInt")
helper_patched = helper_present and all(
    re.search(rf"^\.method[^\n]*\b{name}\(", helper_smali.read_text(encoding="utf-8"), re.M)
    for name in helper_methods
)
helper_unknown = helper_present and not helper_patched

states = {
    "r_c": "patched" if r_c_patched else ("original" if r_c_original else "unknown"),
    "r_e": r_e_state,
    "s_e": "patched" if s_e_patched else ("original" if s_e_original else "unknown"),
    "h_k": "patched" if h_k_patched else ("original" if h_k_original else "unknown"),
    "helper": "patched" if helper_patched else ("original" if not helper_present else "unknown"),
}
if mode == "check":
    if all(state == "patched" for state in states.values()):
        print("patched")
    elif all(state == "original" for state in states.values()):
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

# 逐项幂等处理：original 植入，v1（历史坏版）升级，patched 跳过。
r_new = r_text
if states["r_c"] == "original":
    r_new = r_new.replace(
        r_c_block,
        r_c_block.replace("const/16 v4, 0x45", "const/16 v4, 0x23", 1),
        1,
    )

if states["r_e"] == "original":
    seg = r_e_block.replace("    const/4 v2, 0x0\n\n", "", 1)
    seg = seg.replace(ni_line, inv_block + ni_line, 1)
    r_new = r_new.replace(r_e_block, seg, 1)
elif states["r_e"] == "v1":
    seg = r_e_block.replace(inv_block, "", 1)
    seg = seg.replace(ni_line, inv_block + ni_line, 1)
    r_new = r_new.replace(r_e_block, seg, 1)

write_file(r_smali, r_new, "DSP L1 置信度与 LAB 前视缓冲")

if states["s_e"] == "original":
    write_file(s_smali, vp_gate.sub(lambda _match: vp_bypass, s_text, count=1), "声纹门放行")

if states["h_k"] == "original":
    h_k_reg = h_k_duration.search(h_k_block).group(1)
    write_file(
        h_smali,
        h_text.replace(
            h_k_block,
            h_k_block.replace(
                f"const-wide/16 {h_k_reg}, 0x320",
                f"const-wide/16 {h_k_reg}, 0x1b58",
                1,
            ),
            1,
        ),
        "DSP 回调保活时长",
    )

if states["helper"] != "patched":
    file_mode = stat.S_IMODE(wakeup_dir.stat().st_mode)
    helper_tmp = helper_smali.with_name(f".{helper_smali.name}.tmp")
    helper_tmp.write_text(helper_source, encoding="utf-8")
    os.chmod(helper_tmp, file_mode)
    os.replace(helper_tmp, helper_smali)

print("patched ok")
PY
}

STATE=$(voicetrigger_edits_state check)
case "$STATE" in
    patched)
        log "SKIP：VoiceTrigger 小爱唤醒修复已植入"
        exit 0
        ;;
    original|partial) ;;
    *)
        fail "VoiceTrigger 目标方法结构与当前支持版本不一致，拒绝盲目修改：state=$STATE"
        ;;
esac

DEX_ENTRY=$(smali_dex_entry "$DECODE_DIR/$WAKEUP_DIR_REL/r.smali")
[[ "$(apk_patcher_entry_count "$APK_PATH" "$DEX_ENTRY")" == 1 ]] ||
    fail "原 APK 中 $DEX_ENTRY 数量异常"

log "修改 VoiceTrigger 唤醒链路（目标 DEX：$DEX_ENTRY，state=$STATE）"
PATCH_RESULT=$(voicetrigger_edits_state patch) || fail "修改 VoiceTrigger Smali 失败"
[[ "$PATCH_RESULT" == 'patched ok' ]] || fail "VoiceTrigger Smali 未产生预期修改：$PATCH_RESULT"
[[ "$(voicetrigger_edits_state check)" == 'patched' ]] || fail "修改后的 VoiceTrigger Smali 校验失败"

apk_patcher_record_entry "$DEX_ENTRY" || fail "无法登记 VoiceTrigger.apk 目标 DEX"
apk_patcher_finalize || fail "VoiceTrigger.apk 最终回编译失败"
log "APPLY：补丁完成：$APK_PATH"
