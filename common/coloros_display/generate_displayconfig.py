#!/usr/bin/env python3
"""Generate Android DisplayDeviceConfig from the ColorOS brightness tables."""

from __future__ import annotations

import argparse
import bisect
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


def fail(message: str) -> None:
    raise SystemExit(f"亮度表生成失败：{message}")


def parse_level(text: str, source: Path) -> tuple[int, float]:
    fields = [field.strip() for field in text.split(",")]
    if len(fields) < 3:
        fail(f"{source} 存在格式错误的 brightness level")
    try:
        return int(fields[0]), float(fields[2])
    except ValueError:
        fail(f"{source} 存在非数字 brightness level：{text!r}")


def parse_panel(path: Path) -> tuple[list[float], int, int, int]:
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        fail(f"无法读取面板亮度表 {path}: {exc}")
    table = root.find("brightness_table")
    if table is None:
        fail(f"面板亮度表缺少 brightness_table：{path}")
    levels = [parse_level(node.text or "", path) for node in table.findall("level")]
    if len(levels) < 2:
        fail(f"面板亮度表 level 数量不足：{path}")
    values = [level for level, _ in levels]
    if values != list(range(len(values))):
        fail(f"面板亮度 level 必须从 0 连续排列：{path}")
    nits = [nit for _, nit in levels]
    if any(not math.isfinite(nit) or nit < 0 for nit in nits):
        fail(f"面板亮度表包含无效 nit：{path}")
    if any(nits[index] < nits[index - 1] for index in range(1, len(nits))):
        fail(f"面板亮度表 nit 非单调：{path}")
    try:
        normal_max = int(table.attrib["max"])
        lux_mode = int(root.findtext("lux_table_mode", "0"))
        hbm_lux_mode = int(root.findtext("hbm_lux_table_mode", "0"))
    except ValueError:
        fail(f"面板亮度表的 max/lux mode 无效：{path}")
    if not 0 <= normal_max < len(nits):
        fail(f"面板亮度表 max 超出 level 范围：{normal_max}")
    return nits, normal_max, lux_mode, hbm_lux_mode


def parse_lux(path: Path) -> list[tuple[float, float]]:
    try:
        root = ET.parse(path).getroot()
    except (ET.ParseError, OSError) as exc:
        fail(f"无法读取 ColorOS lux 表 {path}: {exc}")
    table = root.find("lux_table[@name='expressiveness']")
    if table is None:
        fail(f"缺少 expressiveness lux_table：{path}")
    points: list[tuple[float, float]] = []
    for node in table.findall("lux"):
        fields = [field.strip() for field in (node.text or "").split(",")]
        if len(fields) != 2:
            fail(f"lux 点格式错误：{node.text!r}")
        try:
            point = float(fields[0]), float(fields[1])
        except ValueError:
            fail(f"lux 点包含非数字：{node.text!r}")
        if not all(math.isfinite(value) and value >= 0 for value in point):
            fail(f"lux 点包含无效值：{node.text!r}")
        points.append(point)
    if not points or points[0][0] != 0:
        fail("expressiveness lux 表必须从 0 lux 开始")
    if any(points[index][0] <= points[index - 1][0]
           for index in range(1, len(points))):
        fail("expressiveness lux 表 lux 必须严格递增")
    return points


def backlight_for_nit(nit: float, nits: list[float]) -> float:
    if nit <= nits[0]:
        return 0.0
    if nit >= nits[-1]:
        return 1.0
    high = bisect.bisect_left(nits, nit)
    low = high - 1
    if nits[high] == nits[low]:
        level = float(high)
    else:
        level = low + (nit - nits[low]) / (nits[high] - nits[low])
    return level / (len(nits) - 1)


def fmt(value: float, digits: int) -> str:
    return f"{value:.{digits}f}"


def generate(panel: Path, lux_path: Path, output: Path, display_id: str,
             hbm_enter: int) -> None:
    if not re.fullmatch(r"[1-9][0-9]{0,19}", display_id):
        fail(f"Display ID 无效：{display_id}")
    expected_name = f"display_id_{display_id}.xml"
    if output.name != expected_name:
        fail(f"输出文件名必须是 {expected_name}")
    if hbm_enter <= 0:
        fail("HBM enter lux 必须为正数")

    nits, normal_max, lux_mode, hbm_lux_mode = parse_panel(panel)
    lux_points = parse_lux(lux_path)
    total_max = len(nits) - 1
    if normal_max == total_max:
        fail("面板亮度表没有扩展 HBM 区间")

    auto_points: list[tuple[float, float]] = []
    for lux, nit in lux_points:
        brightness = 1.0 if lux >= hbm_enter else backlight_for_nit(nit, nits)
        if auto_points and brightness < auto_points[-1][1]:
            brightness = auto_points[-1][1]
        auto_points.append((lux, min(1.0, brightness)))
    if not any(lux == hbm_enter for lux, _ in auto_points):
        before = [point for point in auto_points if point[0] < hbm_enter]
        after = [point for point in auto_points if point[0] > hbm_enter]
        auto_points = before + [(float(hbm_enter), 1.0)]
        auto_points.extend((lux, 1.0) for lux, _ in after)
    auto_points = sorted(auto_points)

    lines = [
        '<?xml version="1.0" encoding="utf-8"?>',
        "<displayConfiguration>",
        f"  <!-- Generated from my_product ColorOS tables for display {display_id}. -->",
        '  <screenBrightnessMap interpolation="linear">',
    ]
    for level, nit in enumerate(nits):
        lines.extend([
            "    <point>",
            f"      <value>{fmt(level / total_max, 9)}</value>",
            f"      <nits>{fmt(nit, 6)}</nits>",
            "    </point>",
        ])
    lines.extend([
        "  </screenBrightnessMap>",
        "",
        '  <highBrightnessMode enabled="true">',
        f"    <transitionPoint>{fmt(normal_max / total_max, 9)}</transitionPoint>",
        "    <minimumHdrPercentOfScreen>0.1</minimumHdrPercentOfScreen>",
        f"    <minimumLux>{hbm_enter}</minimumLux>",
        "    <timing>",
        "      <timeWindowSecs>1800</timeWindowSecs>",
        "      <timeMaxSecs>300</timeMaxSecs>",
        "      <timeMinSecs>60</timeMinSecs>",
        "    </timing>",
        "    <sdrHdrRatioMap>",
        "      <point><sdrNits>2.000</sdrNits><hdrRatio>8.000</hdrRatio></point>",
        "      <point><sdrNits>500.000</sdrNits><hdrRatio>1.500</hdrRatio></point>",
        "    </sdrHdrRatioMap>",
        "  </highBrightnessMode>",
        "",
        '  <autoBrightness enabled="true">',
        "    <brighteningLightDebounceMillis>1000</brighteningLightDebounceMillis>",
        "    <darkeningLightDebounceMillis>1000</darkeningLightDebounceMillis>",
        "    <luxToBrightnessMapping>",
        "      <map>",
    ])
    for lux, brightness in auto_points:
        lines.extend([
            "        <point>",
            f"          <first>{fmt(lux, 6).rstrip('0').rstrip('.')}</first>",
            f"          <second>{fmt(brightness, 9)}</second>",
            "        </point>",
        ])
    lines.extend([
        "      </map>",
        "      <mode>default</mode>",
        "      <setting>normal</setting>",
        "    </luxToBrightnessMapping>",
        "  </autoBrightness>",
        "  <screenBrightnessRampFastDecrease>0.06</screenBrightnessRampFastDecrease>",
        "  <screenBrightnessRampFastIncrease>0.06</screenBrightnessRampFastIncrease>",
        "  <screenBrightnessRampSlowDecrease>0.04</screenBrightnessRampSlowDecrease>",
        "  <screenBrightnessRampSlowIncrease>0.04</screenBrightnessRampSlowIncrease>",
        "  <screenBrightnessRampIncreaseMaxMillis>3000</screenBrightnessRampIncreaseMaxMillis>",
        "  <screenBrightnessRampDecreaseMaxMillis>3000</screenBrightnessRampDecreaseMaxMillis>",
        "</displayConfiguration>",
    ])
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text("\n".join(lines) + "\n", encoding="utf-8")
    print(f"DISPLAY_CONFIG_OK={output}")
    print(f"PHYSICAL_POINTS={len(nits)}")
    print(f"AUTO_POINTS={len(auto_points)}")
    print(f"LUX_MODE={lux_mode}")
    print(f"HBM_LUX_MODE={hbm_lux_mode}")
    print(f"HBM_ENTER_LUX={hbm_enter}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--panel", type=Path, required=True)
    parser.add_argument("--lux", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--display-id", required=True)
    parser.add_argument("--hbm-enter-lux", type=int, default=40000)
    args = parser.parse_args()
    generate(args.panel, args.lux, args.output, args.display_id, args.hbm_enter_lux)
    return 0


if __name__ == "__main__":
    sys.exit(main())
