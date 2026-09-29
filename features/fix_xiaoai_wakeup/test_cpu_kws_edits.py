#!/usr/bin/env python3
"""cpu_kws_edits.py 的行为测试：植入、节奏参数化、幂等收敛与不受支持时拒绝修改。

用最小 Smali 夹具复现六个植入点，不依赖真实 VoiceTrigger.apk。
"""

from __future__ import annotations

import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
EDITS = HERE / "cpu_kws_edits.py"
CLASS_REL = Path("smali_classes2") / "com" / "miui" / "voicetrigger" / "wakeup" / "PortCpuKws.smali"

F_SMALI = """\
.class public final Lcom/miui/voicetrigger/wakeup/F;
.super Ljava/lang/Object;

.method protected o(Z)V
    .locals 4

    const-string v0, ""

    if-eqz p1, :cond_3

    iget-object p1, p0, Lcom/miui/voicetrigger/wakeup/F;->g:Lcom/miui/voicetrigger/wakeup/r;

    return-void

    :cond_3
    invoke-static {}, Lcom/miui/voicetrigger/wakeup/u;->i()Lcom/miui/voicetrigger/wakeup/u;

    return-void
.end method

.method public final S()V
    .locals 4

    iget-object v0, p0, Lcom/miui/voicetrigger/wakeup/F;->g:Lcom/miui/voicetrigger/wakeup/r;

    return-void
.end method
"""

H_SMALI = """\
.class public final Lcom/miui/voicetrigger/wakeup/H;
.super Ljava/lang/Object;

.method public final k(Z)V
    .locals 2

    invoke-virtual {p0}, Lcom/miui/voicetrigger/wakeup/H;->n()V

    if-nez p1, :cond_0

    const-string p1, "engine not pass"

    return-void

    :cond_0
    sget-object p1, Lv0/B;->a:Lv0/B;

    return-void
.end method
"""

S_SMALI = """\
.class public final Lcom/miui/voicetrigger/wakeup/s;
.super Ljava/lang/Object;

.method public e(Lcom/miui/voicetrigger/wakeup/w;)V
    .locals 4

    const-string p1, "v5.app.wakeup.level2.finish"

    invoke-static {p1}, Lv0/a;->a(Ljava/lang/String;)V

    new-instance v0, Landroid/os/Bundle;

    invoke-direct {v0}, Landroid/os/Bundle;-><init>()V

    return-void
.end method
"""

T_SMALI = """\
.class public final Lcom/miui/voicetrigger/wakeup/t;
.super Ljava/lang/Object;

.field public static final b:I

.method static constructor <clinit>()V
    .locals 1

    if-eqz v0, :cond_1

    const v0, 0x184c0

    sput v0, Lcom/miui/voicetrigger/wakeup/t;->b:I

    goto :goto_1

    :cond_1
    const v0, 0x17700

    sput v0, Lcom/miui/voicetrigger/wakeup/t;->b:I

    :goto_1
    return-void
.end method
"""

WAKEUP_REL = Path("smali_classes2") / "com" / "miui" / "voicetrigger" / "wakeup"


def make_tree(root: Path) -> Path:
    decode = root / "decoded"
    wakeup = decode / WAKEUP_REL
    wakeup.mkdir(parents=True)
    (wakeup / "F.smali").write_text(F_SMALI, encoding="utf-8")
    (wakeup / "H.smali").write_text(H_SMALI, encoding="utf-8")
    (wakeup / "s.smali").write_text(S_SMALI, encoding="utf-8")
    (wakeup / "t.smali").write_text(T_SMALI, encoding="utf-8")
    return decode


def run_edits(mode: str, decode: Path, extra: list[str] | None = None
              ) -> subprocess.CompletedProcess[str]:
    argv = [sys.executable, str(EDITS), mode, str(decode)]
    if extra:
        argv += extra
    return subprocess.run(
        argv,
        capture_output=True, text=True, check=False,
        env={"PYTHONDONTWRITEBYTECODE": "1", "PATH": "/usr/bin:/bin"},
    )


def snapshot(decode: Path) -> dict[str, str]:
    files = {}
    for path in sorted(decode.rglob("*.smali")):
        files[str(path.relative_to(decode))] = path.read_text(encoding="utf-8")
    return files


def expect(condition: bool, message: str) -> None:
    if not condition:
        raise AssertionError(message)


def expect_state(decode: Path, expected: str, extra: list[str] | None = None) -> None:
    check = run_edits("check", decode, extra)
    expect(check.returncode == 0, f"check 应成功：{check.stderr}")
    expect(check.stdout.strip() == expected,
           f"check 应为 {expected}：{check.stdout} {check.stderr}")


def test_default_cadence() -> None:
    """默认节奏必须复现 Ace 6T 刷机验证过的取值，并自动安装 PortCpuKws 资源。"""
    with tempfile.TemporaryDirectory(prefix=".cpu-kws-test.") as raw:
        decode = make_tree(Path(raw))

        expect_state(decode, "original")
        expect(not (decode / CLASS_REL).exists(), "check 不应创建资源文件")

        patch = run_edits("patch", decode)
        expect(patch.returncode == 0, f"默认节奏 patch 应成功：{patch.stderr}")
        expect(patch.stdout.strip() == "patched ok", f"patch 输出异常：{patch.stdout}")

        after = snapshot(decode)
        expect_state(decode, "patched")
        expect((decode / CLASS_REL).is_file(), "未按机型节奏安装 PortCpuKws 资源")

        again = run_edits("patch", decode)
        expect(again.returncode == 0, f"重复植入应成功：{again.stderr}")
        expect(again.stdout.strip() == "already patched", f"重复植入应跳过：{again.stdout}")
        expect(snapshot(decode) == after, "重复植入改动了文件内容，幂等性失败")

        f_text = after[str(WAKEUP_REL / "F.smali")]
        expect(".locals 6" in f_text, "F.o()/F.S() 未扩寄存器以承载 long 参数")
        expect(f_text.count("PortCpuKws;->setEnabled(Z)V") == 2,
               "F.o() 的 enable/disable 登记不完整")
        expect("const-wide/16 v4, 0x0" in f_text, "F.o() 未立即排队首轮采集")
        expect("const-wide/16 v4, 0x5dc" in f_text, "F.S() 未写入默认 1.5s 重开间隔")
        h_text = after[str(WAKEUP_REL / "H.smali")]
        expect("setL1WakeupTime(J)V" in h_text, "H.k() 未补打 L1 时间戳")
        expect("const-wide/16 v2, 0x1388" in h_text, "H.k() 未写入默认 5s 让麦")
        expect("onWakeup()V" in after[str(WAKEUP_REL / "s.smali")], "s.e() 未改投原生唤醒入口")
        expect("const v0, 0x2ee00" in after[str(WAKEUP_REL / "t.smali")],
               "t.b 未写入默认 6s 窗口（192000 字节）")
        expect("const v0, 0x184c0" in after[str(WAKEUP_REL / "t.smali")],
               "t.b 的另一分支被误改")
        expect("const-wide/16 v0, 0x1388" in after[str(CLASS_REL)],
               "PortCpuKws.onWakeup() 未写入默认 5s 让麦")


def test_custom_cadence() -> None:
    """机型注入的节奏值要落到全部四个常量点，并保持幂等。"""
    extra = ["--hold-ms", "4000", "--gap-ms", "800", "--window-sec", "8"]
    with tempfile.TemporaryDirectory(prefix=".cpu-kws-test.") as raw:
        decode = make_tree(Path(raw))

        expect_state(decode, "original", extra)
        patch = run_edits("patch", decode, extra)
        expect(patch.returncode == 0, f"自定义节奏 patch 应成功：{patch.stderr}")
        expect_state(decode, "patched", extra)

        after = snapshot(decode)
        expect("const-wide/16 v4, 0x320" in after[str(WAKEUP_REL / "F.smali")],
               "F.S() 未写入机型间隔 800ms")
        expect("const-wide/16 v2, 0xfa0" in after[str(WAKEUP_REL / "H.smali")],
               "H.k() 未写入机型让麦 4000ms")
        expect("const v0, 0x3e800" in after[str(WAKEUP_REL / "t.smali")],
               "t.b 未写入机型 8s 窗口（256000 字节）")
        expect("const v0, 0x184c0" in after[str(WAKEUP_REL / "t.smali")],
               "改写窗口时误动了 t.b 的另一分支")
        expect("const-wide/16 v0, 0xfa0" in after[str(CLASS_REL)],
               "PortCpuKws.onWakeup() 未写入机型让麦 4000ms")

        again = run_edits("patch", decode, extra)
        expect(again.stdout.strip() == "already patched", f"重复植入应跳过：{again.stdout}")
        expect(snapshot(decode) == after, "自定义节奏重复植入改动文件，幂等性失败")


def test_wide32_encoding() -> None:
    """超过 16 位立即数范围的让麦时长要换成 const-wide/32，仍占同一寄存器对。"""
    extra = ["--hold-ms", "40000"]
    with tempfile.TemporaryDirectory(prefix=".cpu-kws-test.") as raw:
        decode = make_tree(Path(raw))
        patch = run_edits("patch", decode, extra)
        expect(patch.returncode == 0, f"const-wide/32 节奏 patch 应成功：{patch.stderr}")
        expect_state(decode, "patched", extra)

        after = snapshot(decode)
        expect("const-wide/32 v2, 0x00009c40" in after[str(WAKEUP_REL / "H.smali")],
               "H.k() 未用 const-wide/32 编码 40000ms")
        expect("const-wide/32 v0, 0x00009c40" in after[str(CLASS_REL)],
               "PortCpuKws 未用 const-wide/32 编码 40000ms")


def test_hold_gap_change_converges() -> None:
    """让麦与重开间隔的改值要能在已植入树上原位收敛，不留下重复块。"""
    with tempfile.TemporaryDirectory(prefix=".cpu-kws-test.") as raw:
        decode = make_tree(Path(raw))
        expect(run_edits("patch", decode).returncode == 0, "首轮默认植入应成功")

        extra = ["--hold-ms", "9000", "--gap-ms", "300"]
        expect_state(decode, "partial", extra)
        patch = run_edits("patch", decode, extra)
        expect(patch.returncode == 0, f"让麦/间隔改值应成功：{patch.stderr}")
        expect_state(decode, "patched", extra)

        after = snapshot(decode)
        f_text = after[str(WAKEUP_REL / "F.smali")]
        h_text = after[str(WAKEUP_REL / "H.smali")]
        t_text = after[str(WAKEUP_REL / "t.smali")]
        class_text = after[str(CLASS_REL)]
        expect("const-wide/16 v4, 0x12c" in f_text and "0x5dc" not in f_text,
               "F.S() 间隔未收敛到机型值")
        expect("const-wide/16 v2, 0x2328" in h_text and "0x1388" not in h_text,
               "H.k() 让麦未收敛到机型值")
        expect("const-wide/16 v0, 0x2328" in class_text and "0x1388" not in class_text,
               "PortCpuKws 让麦未收敛到机型值")
        expect("const v0, 0x2ee00" in t_text, "未请求改窗口时窗口不应漂移")
        expect(f_text.count("PortCpuKws;->arm(") == 2,
               "F.smali 的 arm 调用数不是首轮+重开两份")
        expect(h_text.count("invoke-static {v2, v3}, Lcom/miui/voicetrigger/"
                            "wakeup/PortCpuKws;->armStored(J)V") == 1,
               "H.k() 出现重复让麦写入")
        expect(class_text.count("invoke-static {v0, v1}, Lcom/miui/voicetrigger/"
                               "wakeup/PortCpuKws;->armStored(J)V") == 1,
               "PortCpuKws 出现重复让麦写入")
        expect(t_text.count("sput v0, Lcom/miui/voicetrigger/wakeup/t;->b:I") == 2,
               "t.b 的两个分支写入数量变化")


def test_window_change_requires_master() -> None:
    """已植入的窗口常量与请求值不同时无法安全归因，必须拒绝并提示取回母本。"""
    with tempfile.TemporaryDirectory(prefix=".cpu-kws-test.") as raw:
        decode = make_tree(Path(raw))
        expect(run_edits("patch", decode).returncode == 0, "首轮默认植入应成功")
        before = snapshot(decode)

        extra = ["--window-sec", "4"]
        expect_state(decode, "unknown", extra)
        patch = run_edits("patch", decode, extra)
        expect(patch.returncode != 0, "窗口改值必须拒绝修改")
        expect("INPUT 母本" in patch.stderr, f"失败信息应提示取回母本：{patch.stderr}")
        expect(snapshot(decode) == before, "拒绝修改时却改动了文件")


def test_refuses_unsupported_structure() -> None:
    with tempfile.TemporaryDirectory(prefix=".cpu-kws-test.") as raw:
        decode = make_tree(Path(raw))
        f_path = decode / WAKEUP_REL / "F.smali"
        base = f_path.read_text(encoding="utf-8")
        # 多出一份 enable 锚点，模拟“锚点数量不为 1”的版本漂移。
        duplicated = base + "\n" + (
            "    if-eqz p1, :cond_3\n\n"
            "    iget-object p1, p0, Lcom/miui/voicetrigger/wakeup/F;->g:"
            "Lcom/miui/voicetrigger/wakeup/r;\n"
        )
        f_path.write_text(duplicated, encoding="utf-8")

        expect_state(decode, "unknown")
        patch = run_edits("patch", decode)
        expect(patch.returncode != 0, "漂移版本必须拒绝修改")
        expect("拒绝盲目修改" in patch.stderr, f"失败信息不明确：{patch.stderr}")
        expect(duplicated == f_path.read_text(encoding="utf-8"), "拒绝修改时却改动了文件")
        expect(not (decode / CLASS_REL).exists(), "拒绝修改时却安装了资源")


def test_refuses_missing_class_source() -> None:
    with tempfile.TemporaryDirectory(prefix=".cpu-kws-test.") as raw:
        decode = make_tree(Path(raw))
        before = snapshot(decode)
        missing = Path(raw) / "absent" / "PortCpuKws.smali"
        patch = run_edits("patch", decode, ["--class-source", str(missing)])
        expect(patch.returncode != 0, "缺少 PortCpuKws 资源时不应报成功")
        expect("PortCpuKws" in patch.stderr, f"失败原因应指出缺失资源：{patch.stderr}")
        expect(snapshot(decode) == before, "资源缺失时却改动了目标类")


def test_rejects_out_of_range_cadence() -> None:
    with tempfile.TemporaryDirectory(prefix=".cpu-kws-test.") as raw:
        decode = make_tree(Path(raw))
        for extra in (["--window-sec", "0"], ["--hold-ms", "70000"],
                      ["--gap-ms", "60001"], ["--hold-ms", "abc"],
                      ["--hold-ms", "05000"]):
            patch = run_edits("patch", decode, extra)
            expect(patch.returncode != 0, f"越界节奏值应被拒绝：{extra}")
            check = run_edits("check", decode, extra)
            expect(check.returncode != 0, f"越界节奏值 check 也应失败：{extra}")
        expect(snapshot(decode) == {"smali_classes2/com/miui/voicetrigger/wakeup/"
                                    "F.smali": F_SMALI,
                                    "smali_classes2/com/miui/voicetrigger/wakeup/"
                                    "H.smali": H_SMALI,
                                    "smali_classes2/com/miui/voicetrigger/wakeup/"
                                    "s.smali": S_SMALI,
                                    "smali_classes2/com/miui/voicetrigger/wakeup/"
                                    "t.smali": T_SMALI},
               "越界值拒绝路径改动了夹具文件")


def main() -> int:
    tests = [
        test_default_cadence,
        test_custom_cadence,
        test_wide32_encoding,
        test_hold_gap_change_converges,
        test_window_change_requires_master,
        test_refuses_unsupported_structure,
        test_refuses_missing_class_source,
        test_rejects_out_of_range_cadence,
    ]
    for test in tests:
        try:
            test()
        except AssertionError as error:
            print(f"FAIL {test.__name__}: {error}", file=sys.stderr)
            return 1
        print(f"ok   {test.__name__}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
