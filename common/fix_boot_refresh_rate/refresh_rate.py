#!/usr/bin/env python3
"""Read base display capabilities and generate refresh-rate patch data."""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import NoReturn


REFRESH_PROP_NAMES = (
    "ro.vendor.display.default_fps",
    "ro.vendor.display.fod_monitor_default_fps",
    "ro.vendor.display.dynamic_refresh_rate",
    "ro.vendor.mi_sf.new_dynamic_refresh_rate",
)


def fail(message: str) -> NoReturn:
    raise ValueError(message)


def read_props(path: Path, strict_keys: set[str] | None = None) -> dict[str, str]:
    try:
        text = path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"读取底包属性失败：{path}：{error}")

    props: dict[str, str] = {}
    for line_number, raw_line in enumerate(text.splitlines(), 1):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("import "):
            continue
        if "=" not in line:
            fail(f"底包属性第 {line_number} 行缺少等号：{path}")
        key, value = (part.strip() for part in line.split("=", 1))
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", key):
            fail(f"底包属性名无效：{path}:{line_number}:{key}")
        if key in props and strict_keys is not None and key in strict_keys:
            fail(f"底包关键属性重复：{path}:{key}")
        props[key] = value
    return props


def read_required_prop(props: dict[str, str], key: str, path: Path) -> str:
    value = props.get(key, "").strip()
    if not value:
        fail(f"底包缺少有效属性：{path}:{key}")
    return value


def target_version(init_script: Path, platform: str) -> str:
    try:
        lines = init_script.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as error:
        fail(f"读取显示启动脚本失败：{init_script}：{error}")

    versions: set[str] = set()
    in_target_case = False
    case_depth = 0
    active_platforms: set[str] = set()
    for raw_line in lines:
        line = raw_line.split("#", 1)[0].strip()
        if not line:
            continue
        if not in_target_case:
            if re.fullmatch(r"case\s+.*\$target.*\s+in", line):
                in_target_case = True
                case_depth = 1
            continue

        if re.fullmatch(r"case\s+.+\s+in", line):
            case_depth += 1
            continue
        if line == "esac":
            case_depth -= 1
            if case_depth == 0:
                break
            continue
        if case_depth == 1 and line == ";;":
            active_platforms.clear()
            continue
        if case_depth == 1:
            branch_match = re.fullmatch(r"(.+)\)", line)
            if branch_match:
                active_platforms = {
                    item.strip().strip('"\'')
                    for item in branch_match.group(1).split("|")
                }
                continue
        if platform in active_platforms:
            version_match = re.search(
                r"\bsetprop\s+vendor\.display\.target\.version\s+([0-9]+)\b", line
            )
            if version_match:
                versions.add(version_match.group(1))

    if not versions:
        fail(f"显示启动脚本中没有平台 {platform!r} 的 target.version：{init_script}")
    if len(versions) != 1:
        values = ", ".join(sorted(versions, key=int))
        fail(f"平台 {platform!r} 对应多个 target.version（{values}），无法确定生效版本")
    return versions.pop()


def parse_fps(advanced_xml: Path, version: str) -> tuple[list[int], list[int]]:
    try:
        root = ET.parse(advanced_xml).getroot()
    except (OSError, ET.ParseError) as error:
        fail(f"解析刷新率配置失败：{advanced_xml}：{error}")

    devices = [node for node in root.iter("Device") if node.get("version") == version]
    if len(devices) != 1:
        fail(
            f"刷新率配置中的 Device version={version!r} 数量应为 1，"
            f"实际为 {len(devices)}：{advanced_xml}"
        )

    values: set[int] = set()
    for node in devices[0].iter("FpsOffsetMap"):
        value = node.get("fps", "")
        if not value.isdigit() or int(value) <= 0:
            fail(f"刷新率配置存在无效 fps：{advanced_xml}:{value!r}")
        values.add(int(value))
    all_fps = sorted(values, reverse=True)
    ui_fps = [value for value in all_fps if value >= 60]
    if not ui_fps:
        fail(f"刷新率配置没有 >=60Hz 的有效模式：{advanced_xml}:Device {version}")
    return ui_fps, all_fps


def parse_resolutions(resolution_xml: Path) -> tuple[list[int], list[tuple[int, int]]]:
    try:
        root = ET.parse(resolution_xml).getroot()
    except (OSError, ET.ParseError) as error:
        fail(f"解析分辨率配置失败：{resolution_xml}：{error}")

    widths: list[int] = []
    seen_widths: set[int] = set()
    panels: list[tuple[int, int]] = []

    def positive_int(value: str | None, description: str) -> int:
        if value is None or not value.isdigit() or int(value) <= 0:
            fail(f"分辨率配置无效：{resolution_xml}:{description}={value!r}")
        return int(value)

    for panel in root.iter("PanelResolution"):
        panel_width = positive_int(panel.get("width"), "PanelResolution width")
        panel_height = positive_int(panel.get("height"), "PanelResolution height")
        panels.append((panel_width, panel_height))
        if panel_width not in seen_widths:
            widths.append(panel_width)
            seen_widths.add(panel_width)
        for scaling in panel.iter("ScalingResolution"):
            scaling_width = positive_int(scaling.get("w"), "ScalingResolution w")
            positive_int(scaling.get("h"), "ScalingResolution h")
            if scaling_width not in seen_widths:
                widths.append(scaling_width)
                seen_widths.add(scaling_width)

    if not panels:
        fail(f"分辨率配置中没有 PanelResolution：{resolution_xml}")
    return widths, panels


def split_prop_value(value: str | None, prop_name: str) -> tuple[list[int], str | None]:
    if value is None:
        return [], None
    if not value:
        fail(f"底包刷新率属性值为空：{prop_name}")
    head, separator, tail = value.partition(":")
    values: list[int] = []
    for item in head.split(","):
        item = item.strip()
        if not item.isdigit() or int(item) <= 0:
            fail(f"底包刷新率属性格式无效：{prop_name}={value}")
        values.append(int(item))
    if separator:
        tail_values = tail.split(",")
        if any(not item.strip().isdigit() or int(item.strip()) <= 0 for item in tail_values):
            fail(f"底包刷新率属性策略尾部无效：{prop_name}={value}")
    return values, tail if separator else None


def join_prop_value(head: list[int], tail: str | None) -> str:
    result = ",".join(str(value) for value in head)
    return f"{result}:{tail}" if tail is not None else result


def generated_props(
    base_props: dict[str, str], fps: list[int], all_fps: list[int]
) -> dict[str, str]:
    minimum_fps = min(fps)
    maximum_fps = max(fps)
    dynamic_values, dynamic_tail = split_prop_value(
        base_props.get("ro.vendor.display.dynamic_refresh_rate"),
        "ro.vendor.display.dynamic_refresh_rate",
    )
    if not dynamic_values:
        dynamic_values = [value for value in all_fps if value < minimum_fps]
    low_fps = sorted({value for value in dynamic_values if value < minimum_fps}, reverse=True)
    dynamic_head = list(fps) + [value for value in low_fps if value not in fps]

    _, new_dynamic_tail = split_prop_value(
        base_props.get("ro.vendor.mi_sf.new_dynamic_refresh_rate"),
        "ro.vendor.mi_sf.new_dynamic_refresh_rate",
    )
    new_dynamic_head = [maximum_fps]
    if minimum_fps != maximum_fps:
        new_dynamic_head.append(minimum_fps)

    default_fps_values, _ = split_prop_value(
        base_props.get("ro.vendor.display.default_fps"), "ro.vendor.display.default_fps"
    )
    if len(default_fps_values) > 1:
        fail(
            "底包默认刷新率属性只能有一个值："
            f"ro.vendor.display.default_fps={base_props['ro.vendor.display.default_fps']}"
        )
    default_fps = default_fps_values[0] if default_fps_values else minimum_fps
    if default_fps not in fps:
        default_fps = minimum_fps

    return {
        "ro.vendor.display.default_fps": str(default_fps),
        "ro.vendor.display.fod_monitor_default_fps": str(maximum_fps),
        "ro.vendor.display.dynamic_refresh_rate": join_prop_value(dynamic_head, dynamic_tail),
        "ro.vendor.mi_sf.new_dynamic_refresh_rate": join_prop_value(
            new_dynamic_head, new_dynamic_tail
        ),
    }


def patch_feature_xml(
    feature_path: Path,
    widths: list[int] | None,
    fps: list[int],
    output_path: Path,
) -> None:
    try:
        original_text = feature_path.read_text(encoding="utf-8")
    except (OSError, UnicodeError) as error:
        fail(f"读取机型配置失败：{feature_path}：{error}")
    newline = "\r\n" if "\r\n" in original_text else "\n"

    def replace_integer(text: str, name: str, value: int) -> str:
        pattern = re.compile(
            rf'(?m)^([ \t]*)<integer name="{re.escape(name)}">[^<]*</integer>[ \t]*$'
        )
        updated, count = pattern.subn(
            lambda match: f'{match.group(1)}<integer name="{name}">{value}</integer>', text
        )
        if count != 1:
            fail(f"机型配置中的 {name} 数量应为 1，实际为 {count}：{feature_path}")
        return updated

    def array_block(indent: str, name: str, values: list[int]) -> str:
        lines = [f'{indent}<integer-array name="{name}">']
        lines.extend(f"{indent}    <item>{value}</item>" for value in values)
        lines.append(f"{indent}</integer-array>")
        return newline.join(lines)

    def replace_array(text: str, name: str, values: list[int], required: bool) -> tuple[str, int]:
        pattern = re.compile(
            rf'(?ms)^([ \t]*)<integer-array name="{re.escape(name)}">.*?</integer-array>[ \t]*$'
        )
        updated, count = pattern.subn(
            lambda match: array_block(match.group(1), name, values), text
        )
        if count > 1 or (required and count != 1):
            expected = "1" if required else "0 或 1"
            fail(f"机型配置中的 {name} 数量应为 {expected}，实际为 {count}：{feature_path}")
        return updated, count

    updated = replace_integer(original_text, "smart_fps_value", fps[0])
    updated, _ = replace_array(updated, "fpsList", fps, True)
    if widths is not None:
        updated, resolution_count = replace_array(
            updated, "screen_resolution_supported", widths, False
        )
        if resolution_count == 0:
            block = array_block("    ", "screen_resolution_supported", widths)
            marker = re.compile(r"(?m)^[ \t]*<!-- Display BEGIN -->[ \t]*$")
            marker_matches = list(marker.finditer(updated))
            if len(marker_matches) == 1:
                match = marker_matches[0]
                updated = updated[: match.end()] + newline + block + updated[match.end() :]
            else:
                end_features = re.compile(r"(?m)^[ \t]*</features>[ \t]*$")
                end_matches = list(end_features.finditer(updated))
                if len(end_matches) != 1:
                    fail(f"无法唯一定位 Display BEGIN 或 </features>：{feature_path}")
                match = end_matches[0]
                updated = updated[: match.start()] + block + newline + updated[match.start() :]

    try:
        ET.fromstring(updated)
        output_path.write_text(updated, encoding="utf-8", newline="")
    except (ET.ParseError, OSError) as error:
        fail(f"写入修改后的机型配置失败：{output_path}：{error}")


def build_model(args: argparse.Namespace) -> dict[str, object]:
    vendor_props = read_props(Path(args.vendor_prop), {"ro.board.platform"})
    platform = read_required_prop(vendor_props, "ro.board.platform", Path(args.vendor_prop))
    version = target_version(Path(args.init_script), platform)
    fps, all_fps = parse_fps(Path(args.advanced_xml), version)
    result: dict[str, object] = {
        "platform": platform,
        "target_version": version,
        "fps": fps,
    }
    if args.odm_prop:
        odm_props = read_props(Path(args.odm_prop), set(REFRESH_PROP_NAMES))
        result["props"] = generated_props(odm_props, fps, all_fps)
    if args.resolution_xml:
        widths, panels = parse_resolutions(Path(args.resolution_xml))
        result["widths"] = widths
        result["panels"] = panels
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--vendor-prop", required=True)
    parser.add_argument("--odm-prop")
    parser.add_argument("--init-script", required=True)
    parser.add_argument("--advanced-xml", required=True)
    parser.add_argument("--resolution-xml")
    parser.add_argument("--model-output", required=True)
    parser.add_argument("--props-output")
    parser.add_argument("--feature-input")
    parser.add_argument("--feature-output")
    args = parser.parse_args()

    try:
        model = build_model(args)
        if bool(args.odm_prop) != bool(args.props_output):
            fail("odm-prop 与 props-output 必须同时提供")
        if bool(args.feature_input) != bool(args.feature_output):
            fail("feature-input 与 feature-output 必须同时提供")
        if args.feature_input:
            raw_widths = model.get("widths")
            widths = (
                [int(value) for value in raw_widths]
                if isinstance(raw_widths, list)
                else None
            )
            patch_feature_xml(
                Path(args.feature_input),
                widths,
                [int(value) for value in model["fps"]],
                Path(args.feature_output),
            )
        if args.props_output:
            props = model.get("props")
            if not isinstance(props, dict):
                fail("缺少底包 ODM 属性，无法生成刷新率属性")
            Path(args.props_output).write_text(
                "".join(f"{key}={props[key]}\n" for key in REFRESH_PROP_NAMES),
                encoding="utf-8",
            )
        Path(args.model_output).write_text(
            json.dumps(model, ensure_ascii=False, sort_keys=True), encoding="utf-8"
        )
    except ValueError as error:
        print(str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
