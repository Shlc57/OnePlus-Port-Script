#!/usr/bin/env python3
"""VoiceTrigger CPU FlexKws 前端的 Smali 改法（check/patch 两种模式）。

用法：cpu_kws_edits.py <check|patch> <apktool解包目录>
                     [--hold-ms N] [--gap-ms N] [--window-sec N] [--class-source FILE]

背景：Oplus SM8845 底包的 ADSP 固件不接受小米 CUSTOM1 模型（StartRecognition
停在 gsl_graph_send_nonpersist_cal failed 2 → createMmapBuffer -22，会反复打死
audioserver），而原包 VoiceTrigger.apk 自带完整的 CPU 唤醒栈：
wakeup/c（AudioRecord source=VOICE_COMMUNICATION + libflexkws）→ wakeup/u
（MIXWVPWakeupSession）→ wakeup/v（声纹判定）→ wakeup/s（结果投递）。
唯一缺的是启动点：CPU 采集只被 wakeup/F.onRecognition（DSP L1 命中）驱动。
本脚本因此做六处改动：

1. wakeup/F.o(enable=true)：不再建立 ADSP 会话（r.g 会触发 -22），改为登记参数
   并立即排队一轮 CPU 采集；
2. wakeup/F.o(enable=false)：清 enabled，使排队中的重开自然失效；
3. wakeup/F.S()：原本重启 ADSP 识别（r.k），改为短延时后重排一轮 CPU 采集；
4. wakeup/H.k(passed=true)：补打 L1 时间戳（不经 onRecognition 时 WakeupInfoBean
   的 level1.finish 会是 0，小爱拿到 wakeupCostTime=Long.MAX 的非法时序），并压一个
   让麦窗口，避免对话期间抢开第二路采集；
5. wakeup/s.e(result)：仅在 KWS 与声纹双通过的分支里，把结果投递换成原生唤醒入口
   ACTION_VOICE_TRIGGER_START_VOICEASSIST（不含 oneshot_messenger，让小爱自己开麦，
   同时保留应答反馈）；
6. wakeup/t.b：CPU 检出窗口加长，提高常开监听占空比。

三个节奏常量由机型参数注入，默认值就是 Ace 6T 刷机验证过的取值：
`--hold-ms`（唤醒后让麦时长，默认 5000ms，同时写入 H.k() 与 PortCpuKws.onWakeup()）、
`--gap-ms`（一轮无检出后重开下一轮的间隔，默认 1500ms，写入 F.S()）、
`--window-sec`（CPU 检出窗口，默认 6s，按单声道 int16/16kHz 即 32000 B/s 换算成
字节数写入 wakeup/t.b）。窗口字节数只在该路线锁定的单声道格式下成立，见机型
`ro.vendor.audio.soundtrigger.support_record_type=-1` 的说明。

约束：只做文本级精确锚点替换，锚点数量不符即拒绝修改；重复执行得到同一结果；
已植入但节奏值不同时判为 stale，并用同一套锚点改写收敛到新值。
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

# 单声道 16kHz int16：support_record_type=-1 时 wakeup/c 实际使用的采样格式。
BYTES_PER_SEC = 32000
DEFAULT_HOLD_MS = 5000
DEFAULT_GAP_MS = 1500
DEFAULT_WINDOW_SEC = 6
HOLD_MS_MIN, HOLD_MS_MAX = 100, 60000
GAP_MS_MIN, GAP_MS_MAX = 0, 60000
WINDOW_SEC_MIN, WINDOW_SEC_MAX = 1, 600
# 原包 wakeup/t.b 的 3 秒窗口（0x17700），用于区分“未植入”与“已植入旧值”。
ORIGINAL_WINDOW_BYTES = 0x17700

CLASS_NAME = "PortCpuKws"
CLASS_PATH = ("smali_classes2", "com", "miui", "voicetrigger", "wakeup",
              "PortCpuKws.smali")
CLASS_SOURCE_DEFAULT = Path(__file__).resolve().parent / "config" / "PortCpuKws.smali"

ARM_SIG = ("Lcom/miui/voicetrigger/wakeup/PortCpuKws;->"
           "arm(Landroid/os/Bundle;Lcom/miui/voicetrigger/wakeup/E;"
           "Ljava/lang/String;J)V")
ENABLED_SIG = "Lcom/miui/voicetrigger/wakeup/PortCpuKws;->setEnabled(Z)V"
ARM_STORED_SIG = "Lcom/miui/voicetrigger/wakeup/PortCpuKws;->armStored(J)V"
ONWAKEUP_SIG = "Lcom/miui/voicetrigger/wakeup/PortCpuKws;->onWakeup()V"

F_ENABLE_ANCHOR = (
    "    if-eqz p1, :cond_3\n\n"
    "    iget-object p1, p0, Lcom/miui/voicetrigger/wakeup/F;->g:"
    "Lcom/miui/voicetrigger/wakeup/r;\n"
)
F_DISABLE_ANCHOR = (
    "    :cond_3\n"
    "    invoke-static {}, Lcom/miui/voicetrigger/wakeup/u;->i()"
    "Lcom/miui/voicetrigger/wakeup/u;\n"
)
F_METHOD_HEAD = ".method protected o(Z)V\n    .locals 4\n"
S_METHOD_SIG = ".method public final S()V\n"
S_METHOD_HEAD = S_METHOD_SIG + "    .locals 4\n"
H_METHOD_HEAD = ".method public final k(Z)V\n    .locals 2\n"
H_PASS_ANCHOR = (
    "    :cond_0\n"
    "    sget-object p1, Lv0/B;->a:Lv0/B;\n"
)
S_DELIVER_ANCHOR = (
    '    const-string p1, "v5.app.wakeup.level2.finish"\n\n'
    "    invoke-static {p1}, Lv0/a;->a(Ljava/lang/String;)V\n"
)
# s.e() 是在锚点之后追加投递，锚点本身不会被消耗；状态判据用“植入前后的邻接形态”区分。
S_DELIVER_ORIGINAL = S_DELIVER_ANCHOR + "\n    new-instance v0, Landroid/os/Bundle;\n"
S_DELIVER_PATCHED = S_DELIVER_ANCHOR + "\n    invoke-static {}, " + ONWAKEUP_SIG + "\n"

# 节奏常量的落点块：常量行 + 紧随其后的调用行。整块匹配，值不同时仍可原位改写。
S_RESTART_BLOCK = re.compile(
    "    const-wide(?:/16|/32)? v4, (?P<value>0x[0-9a-fA-F]+)\\n\\n"
    "    invoke-static \\{v0, v1, v2, v4, v5\\}, " + re.escape(ARM_SIG) + "\\n"
)
H_HOLD_BLOCK = re.compile(
    "    const-wide(?:/16|/32)? v2, (?P<value>0x[0-9a-fA-F]+)\\n\\n"
    "    invoke-static \\{v2, v3\\}, " + re.escape(ARM_STORED_SIG) + "\\n"
)
CLASS_HOLD_BLOCK = re.compile(
    "    const-wide(?:/16|/32)? v0, (?P<value>0x[0-9a-fA-F]+)\\n\\n"
    "    invoke-static \\{v0, v1\\}, " + re.escape(ARM_STORED_SIG) + "\\n"
)
T_WINDOW_BLOCK = re.compile(
    "    const v0, (?P<value>0x[0-9a-fA-F]+)\\n\\n"
    "    sput v0, Lcom/miui/voicetrigger/wakeup/t;->b:I\\n"
)


def fail(message: str) -> None:
    print(message, file=sys.stderr)
    raise SystemExit(1)


def wide_const(register: str, value: int) -> str:
    """按 baksmali 形态编码一个 long 常量，只占用指定的寄存器对。"""
    if -0x8000 <= value <= 0x7FFF:
        return f"const-wide/16 {register}, {value:#x}"
    if -0x80000000 <= value <= 0x7FFFFFFF:
        return f"const-wide/32 {register}, {value:#010x}"
    fail(f"时间常量超出可编码范围（需要 64 位立即数）：{value}")


class Cadence:
    """机型注入的三个节奏常量及其 Smali 形态。"""

    def __init__(self, hold_ms: int, gap_ms: int, window_sec: int) -> None:
        for name, value, low, high in (
            ("xiaoai_cpu_kws_hold_ms", hold_ms, HOLD_MS_MIN, HOLD_MS_MAX),
            ("xiaoai_cpu_kws_gap_ms", gap_ms, GAP_MS_MIN, GAP_MS_MAX),
            ("xiaoai_cpu_kws_window_sec", window_sec, WINDOW_SEC_MIN, WINDOW_SEC_MAX),
        ):
            if not low <= value <= high:
                fail(f"{name} 必须在 {low}~{high} 之间：{value}")
        self.hold_ms = hold_ms
        self.gap_ms = gap_ms
        self.window_sec = window_sec
        self.window_bytes = window_sec * BYTES_PER_SEC
        self.window_literal = f"0x{self.window_bytes:x}"


def literal_values(pattern: re.Pattern[str], text: str) -> list[int]:
    return [int(match.group("value"), 16) for match in pattern.finditer(text)]


def method_body(text: str, signature: str) -> tuple[int, str] | None:
    """返回方法体的偏移与内容，用于把常量判据限定在指定方法里。

    F.o() 的首轮 0 延时与 F.S() 的重开间隔形态相同，不限定方法就会数到两份。
    """
    start = text.find(signature)
    if start < 0:
        return None
    end = text.find("\n.end method", start)
    if end < 0:
        return None
    return start, text[start:end]


def cadence_state(found: list[int], has_pristine_anchor: bool, requested: int,
                  original: int | None = None) -> str:
    if len(found) == 1:
        if found[0] == requested:
            return "patched"
        if original is not None and found[0] == original:
            return "original"
        return "stale"
    if not found and has_pristine_anchor:
        return "original"
    return "unknown"


def restart_state(f_text: str, gap_ms: int) -> str:
    """F.S() 的重开间隔只在 S() 方法体内判定，避开 F.o() 的同形态首轮排队。"""
    body = method_body(f_text, S_METHOD_SIG)
    if body is None:
        return "unknown"
    return cadence_state(literal_values(S_RESTART_BLOCK, body[1]),
                         ".locals 4" in body[1],
                         gap_ms)


def window_state(t_text: str, requested_bytes: int) -> str:
    """wakeup/t.b 的窗口常量判定。

    真包的 <clinit> 按条件写两次 t.b（原包另有一份 0x184c0 分支），因此不能要求
    “全文恰好一个写入块”；只区分原包 3s 值与请求值。两个都不匹配时说明上一次
    植入用的是另一个节奏值，必须从 INPUT 母本取回 VoiceTrigger.apk 重打。
    """
    values = literal_values(T_WINDOW_BLOCK, t_text)
    if requested_bytes in values:
        return "patched"
    if ORIGINAL_WINDOW_BYTES in values:
        return "original"
    return "unknown"


class Tree:
    def __init__(self, decode_dir: Path, cadence: Cadence) -> None:
        root = decode_dir / "smali_classes2" / "com" / "miui" / "voicetrigger" / "wakeup"
        self.cadence = cadence
        self.f = root / "F.smali"
        self.h = root / "H.smali"
        self.s = root / "s.smali"
        self.t = root / "t.smali"
        self.cls = decode_dir.joinpath(*CLASS_PATH)
        self.text: dict[Path, str] = {}
        for path in (self.f, self.h, self.s, self.t):
            if not path.is_file():
                fail(f"目标类缺失，VoiceTrigger 版本不受支持：{path}")
            self.text[path] = path.read_text(encoding="utf-8")

    def save(self, path: Path) -> None:
        path.write_text(self.text[path], encoding="utf-8")


def item_states(tree: Tree) -> dict[str, str]:
    cadence = tree.cadence
    f_text = tree.text[tree.f]
    h_text = tree.text[tree.h]
    s_text = tree.text[tree.s]
    t_text = tree.text[tree.t]

    def arm_state(patched_marks: int, original_anchor: int) -> str:
        # 锚点必须恰好一份：多份或“已植入与未植入共存”都是版本漂移。
        if patched_marks >= 1 and original_anchor == 0:
            return "patched"
        if patched_marks == 0 and original_anchor == 1:
            return "original"
        return "unknown"

    states = {
        "f_enable": arm_state(f_text.count(ENABLED_SIG),
                              f_text.count(F_ENABLE_ANCHOR)),
        "f_disable": arm_state(f_text.count(ENABLED_SIG),
                               f_text.count(F_DISABLE_ANCHOR)),
        "f_restart": restart_state(f_text, cadence.gap_ms),
        "h_pass": cadence_state(literal_values(H_HOLD_BLOCK, h_text),
                                H_PASS_ANCHOR in h_text and ARM_STORED_SIG not in h_text,
                                cadence.hold_ms),
        "s_deliver": ("patched" if S_DELIVER_PATCHED in s_text
                      else ("original" if S_DELIVER_ORIGINAL in s_text else "unknown")),
        "t_window": window_state(t_text, cadence.window_bytes),
    }

    if tree.cls.is_file():
        class_literals = literal_values(CLASS_HOLD_BLOCK,
                                        tree.cls.read_text(encoding="utf-8"))
        states["class"] = ("patched" if class_literals == [cadence.hold_ms]
                           else ("stale" if len(class_literals) == 1 else "unknown"))
    else:
        states["class"] = "original"
    return states


def replace_once(tree: Tree, path: Path, old: str, new: str, label: str) -> None:
    text = tree.text[path]
    if text.count(old) != 1:
        fail(f"{label} 锚点数量应为 1，实际 {text.count(old)}，"
             f"VoiceTrigger 版本不受支持：{path}")
    tree.text[path] = text.replace(old, new, 1)


def rewrite_block(tree: Tree, path: Path, block: re.Pattern[str],
                  replacement: str, label: str, scope: str | None = None) -> None:
    """把已存在的常量块原位改写成请求值（stale 收敛路径）。"""
    text = tree.text[path]
    if scope is None:
        start, segment = 0, text
    else:
        found = method_body(text, scope)
        if found is None:
            fail(f"{label} 找不到目标方法：{path}")
        start, segment = found
    if len(list(block.finditer(segment))) != 1:
        fail(f"{label} 常量块数量应为 1，VoiceTrigger 版本不受支持：{path}")
    updated = block.sub(lambda _match: replacement, segment, count=1)
    tree.text[path] = text[:start] + updated + text[start + len(segment):]


def install_class(cadence: Cadence, class_source: Path, decode_dir: Path) -> None:
    """从仓库资源安装 PortCpuKws，并把让麦时长替换成机型请求值。"""
    if not class_source.is_file():
        fail(f"缺少 CPU KWS 前端资源：{class_source}")
    source = class_source.read_text(encoding="utf-8")
    replacement = (f"    {wide_const('v0', cadence.hold_ms)}\n\n"
                   f"    invoke-static {{v0, v1}}, {ARM_STORED_SIG}\n")
    if len(list(CLASS_HOLD_BLOCK.finditer(source))) != 1:
        fail(f"CPU KWS 资源的让麦常量块不是恰好一份：{class_source}")
    updated = CLASS_HOLD_BLOCK.sub(lambda _match: replacement, source, count=1)
    target = decode_dir.joinpath(*CLASS_PATH)
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(updated, encoding="utf-8")


def apply_patch(tree: Tree, states: dict[str, str]) -> None:
    cadence = tree.cadence
    # PortCpuKws 资源每次从仓库原文重装，保证与请求的让麦时长一致且可重复。
    if states["class"] != "patched":
        fail("内部错误：PortCpuKws 资源应在写入工作树前安装")

    # F.o()：扩寄存器以容纳 long 参数，再替换 enable / disable 两条分支。
    if states["f_enable"] != "patched" or states["f_disable"] != "patched":
        replace_once(tree, tree.f, F_METHOD_HEAD,
                     F_METHOD_HEAD.replace(".locals 4", ".locals 6"), "F.o() 头部")
        replace_once(tree, tree.f, F_ENABLE_ANCHOR,
                     "    if-eqz p1, :cond_3\n\n"
                     "    const/4 v4, 0x1\n\n    invoke-static {v4}, " + ENABLED_SIG + "\n\n"
                     "    iget-object v0, p0, Lcom/miui/voicetrigger/wakeup/o;->c:"
                     "Landroid/os/Bundle;\n\n"
                     "    iget-object v1, p0, Lcom/miui/voicetrigger/wakeup/F;->h:"
                     "Lcom/miui/voicetrigger/wakeup/s;\n\n"
                     "    iget-object v2, p0, Lcom/miui/voicetrigger/wakeup/F;->e:"
                     "Ljava/lang/String;\n\n"
                     "    const-wide/16 v4, 0x0\n\n    invoke-static {v0, v1, v2, v4, v5}, "
                     f"{ARM_SIG}\n\n"
                     "    return-void\n\n"
                     "    iget-object p1, p0, Lcom/miui/voicetrigger/wakeup/F;->g:"
                     "Lcom/miui/voicetrigger/wakeup/r;\n",
                     "F.o() enable 分支")
        replace_once(tree, tree.f, F_DISABLE_ANCHOR,
                     "    :cond_3\n"
                     "    const/4 v4, 0x0\n\n    invoke-static {v4}, " + ENABLED_SIG + "\n\n"
                     "    invoke-static {}, Lcom/miui/voicetrigger/wakeup/u;->i()"
                     "Lcom/miui/voicetrigger/wakeup/u;\n",
                     "F.o() disable 分支")

    # F.S()：不重启 ADSP，改为按请求间隔重排一轮 CPU 采集。
    if states["f_restart"] == "original":
        replace_once(tree, tree.f, S_METHOD_HEAD,
                     ".method public final S()V\n    .locals 6\n\n"
                     "    iget-object v0, p0, Lcom/miui/voicetrigger/wakeup/o;->c:"
                     "Landroid/os/Bundle;\n\n"
                     "    iget-object v1, p0, Lcom/miui/voicetrigger/wakeup/F;->h:"
                     "Lcom/miui/voicetrigger/wakeup/s;\n\n"
                     "    iget-object v2, p0, Lcom/miui/voicetrigger/wakeup/F;->e:"
                     "Ljava/lang/String;\n\n"
                     f"    {wide_const('v4', cadence.gap_ms)}\n\n"
                     f"    invoke-static {{v0, v1, v2, v4, v5}}, {ARM_SIG}\n\n"
                     "    return-void\n",
                     "F.S()")
    elif states["f_restart"] == "stale":
        rewrite_block(tree, tree.f, S_RESTART_BLOCK,
                      f"    {wide_const('v4', cadence.gap_ms)}\n\n"
                      f"    invoke-static {{v0, v1, v2, v4, v5}}, {ARM_SIG}\n",
                      "F.S() 重开间隔", S_METHOD_SIG)

    # H.k(passed)：补 L1 时间戳并压请求时长的让麦窗口。
    if states["h_pass"] == "original":
        replace_once(tree, tree.h, H_METHOD_HEAD,
                     H_METHOD_HEAD.replace(".locals 2", ".locals 4"), "H.k() 头部")
        replace_once(tree, tree.h, H_PASS_ANCHOR,
                     "    :cond_0\n"
                     "    invoke-static {}, Lcom/miui/voicetrigger/wakeup/u;->i()"
                     "Lcom/miui/voicetrigger/wakeup/u;\n\n"
                     "    move-result-object v0\n\n"
                     "    invoke-virtual {v0}, Lcom/miui/voicetrigger/wakeup/u;->j()"
                     "Lcom/miui/voicetrigger/data/WakeupInfoBean;\n\n"
                     "    move-result-object v0\n\n"
                     "    invoke-static {}, Ljava/lang/System;->currentTimeMillis()J\n\n"
                     "    move-result-wide v2\n\n"
                     "    invoke-virtual {v0, v2, v3}, "
                     "Lcom/miui/voicetrigger/data/WakeupInfoBean;->setL1WakeupTime(J)V\n\n"
                     f"    {wide_const('v2', cadence.hold_ms)}\n\n"
                     f"    invoke-static {{v2, v3}}, {ARM_STORED_SIG}\n\n"
                     "    sget-object p1, Lv0/B;->a:Lv0/B;\n",
                     "H.k() passed 分支")
    elif states["h_pass"] == "stale":
        rewrite_block(tree, tree.h, H_HOLD_BLOCK,
                      f"    {wide_const('v2', cadence.hold_ms)}\n\n"
                      f"    invoke-static {{v2, v3}}, {ARM_STORED_SIG}\n",
                      "H.k() 让麦时长")

    # s.e(result)：双通过后改走原生唤醒入口投递（不含 oneshot_messenger）。
    if states["s_deliver"] == "original":
        replace_once(tree, tree.s, S_DELIVER_ANCHOR,
                     S_DELIVER_ANCHOR + "\n"
                     f"    invoke-static {{}}, {ONWAKEUP_SIG}\n\n"
                     "    return-void\n",
                     "s.e() 投递")

    # t.b：CPU 检出窗口按机型秒数换算成字节（只改写原包 3s 那一支）。
    if states["t_window"] == "original":
        replace_once(tree, tree.t,
                     f"    const v0, 0x{ORIGINAL_WINDOW_BYTES:x}\n\n"
                     "    sput v0, Lcom/miui/voicetrigger/wakeup/t;->b:I\n",
                     f"    const v0, {cadence.window_literal}\n\n"
                     "    sput v0, Lcom/miui/voicetrigger/wakeup/t;->b:I\n",
                     "t.b 窗口长度")

    for path in (tree.f, tree.h, tree.s, tree.t):
        tree.save(path)


def parse_args(argv: list[str]) -> tuple[str, Path, Cadence, Path]:
    if len(argv) < 3:
        fail("用法：cpu_kws_edits.py <check|patch> <apktool解包目录>"
             " [--hold-ms N] [--gap-ms N] [--window-sec N] [--class-source FILE]")
    mode, decode_arg = argv[1], argv[2]
    if mode not in {"check", "patch"}:
        fail("操作模式只支持 check 或 patch")
    options = {"--hold-ms": str(DEFAULT_HOLD_MS), "--gap-ms": str(DEFAULT_GAP_MS),
               "--window-sec": str(DEFAULT_WINDOW_SEC),
               "--class-source": str(CLASS_SOURCE_DEFAULT)}
    index = 3
    while index < len(argv):
        name = argv[index]
        if name not in options or index + 1 >= len(argv):
            fail(f"未知或缺少取值的选项：{name}")
        options[name] = argv[index + 1]
        index += 2
    numbers: dict[str, int] = {}
    for name in ("--hold-ms", "--gap-ms", "--window-sec"):
        value = options[name]
        # 与 Shell 侧保持同一套语汇：只接受不带前导 0 的十进制非负整数。
        if not re.fullmatch(r"0|[1-9][0-9]*", value):
            fail(f"{name} 必须是十进制非负整数（不带前导 0）：{value}")
        numbers[name] = int(value)
    return mode, Path(decode_arg), Cadence(numbers["--hold-ms"], numbers["--gap-ms"],
                                           numbers["--window-sec"]), Path(options["--class-source"])


def main(argv: list[str]) -> int:
    mode, decode_dir, cadence, class_source = parse_args(argv)
    if not decode_dir.is_dir():
        fail(f"解包目录不存在：{decode_dir}")

    tree = Tree(decode_dir, cadence)
    states = item_states(tree)

    if mode == "check":
        if any(state == "unknown" for state in states.values()):
            print("unknown")
        elif all(state == "patched" for state in states.values()):
            print("patched")
        elif all(state == "original" for state in states.values()):
            print("original")
        else:
            print("partial")
        return 0

    unknown = [name for name, state in states.items() if state == "unknown"]
    if unknown:
        message = ("CPU KWS 植入点的指令结构不是受支持的状态，拒绝盲目修改："
                   + " ".join(f"{name}={states[name]}" for name in unknown))
        if "t_window" in unknown:
            message += ("\nwakeup/t.b 既不是原包 3s 窗口也不是本次请求值，通常说明上轮植入用了"
                        "另一组节奏；请先从 INPUT 母本取回 VoiceTrigger.apk 再重打。")
        fail(message)
    if all(state == "patched" for state in states.values()):
        print("already patched")
        return 0

    if states["class"] != "patched":
        install_class(cadence, class_source, decode_dir)
        tree = Tree(decode_dir, cadence)
        states = item_states(tree)
    apply_patch(tree, states)

    after = item_states(Tree(decode_dir, cadence))
    not_patched = [name for name, state in after.items() if state != "patched"]
    if not_patched:
        fail("CPU KWS Smali 修改后校验失败：" + " ".join(not_patched))
    print("patched ok")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
