#!/usr/bin/env python3
"""Validate the spoof payload and render Settings' device parameter cache."""

from __future__ import annotations

import argparse
import html
import json
import os
import re
import sys
from pathlib import Path
from typing import Any


ENV_NAME = "DEVICE_PARAMS_SPOOF_JSON"
CACHE_TIMESTAMP_MS = 4102444800000  # 2100-01-01, avoids the 8-hour refresh.
SUPPORTED_ITEM_INDEXES = {0, 1, 2, 3, 4, 7}
LANGUAGE_PATTERN = re.compile(
    r"^[a-zA-Z]{2,3}(?:[-_][a-zA-Z]{2,4}|[A-Z]{2}|[0-9]{3})?$"
)


class PayloadError(ValueError):
    """Raised for an invalid user-supplied payload."""


def fail(path: str, message: str) -> None:
    raise PayloadError(f"{path}: {message}")


def require_object(value: Any, path: str) -> dict[str, Any]:
    if not isinstance(value, dict):
        fail(path, "必须是 JSON 对象")
    return value


def require_string(value: Any, path: str, *, allow_empty: bool = True) -> str:
    if not isinstance(value, str):
        fail(path, "必须是字符串")
    if not allow_empty and not value:
        fail(path, "不能为空")
    return value


def parse_integer(value: Any, path: str) -> int:
    if isinstance(value, bool):
        fail(path, "必须是整数，不能使用布尔值")
    if isinstance(value, int):
        return value
    if isinstance(value, str) and re.fullmatch(r"[+-]?\d+", value.strip()):
        return int(value.strip(), 10)
    fail(path, "必须是整数或数字字符串")


def parse_boolean(value: Any, path: str) -> bool:
    if isinstance(value, bool):
        return value
    if isinstance(value, int) and value in (0, 1):
        return bool(value)
    if isinstance(value, str):
        normalized = value.strip().lower()
        if normalized in {"true", "1", "yes"}:
            return True
        if normalized in {"false", "0", "no"}:
            return False
    fail(path, "必须是 true/false、0/1 或对应字符串")


def get_one_alias(
    payload: dict[str, Any], names: tuple[str, ...], path: str
) -> Any:
    present = [name for name in names if name in payload]
    if len(present) > 1:
        fail(path, f"只能填写其中一个字段：{'、'.join(names)}")
    if not present:
        fail(path, f"缺少字段：{' 或 '.join(names)}")
    return payload[present[0]]


def normalize_language(value: Any) -> str:
    language = require_string(value, "language", allow_empty=False).strip()
    if not LANGUAGE_PATTERN.fullmatch(language):
        fail(
            "language",
            "格式应为 Locale.getLanguage()+Locale.getCountry()，例如 zhCN 或 enUS",
        )
    if "-" in language or "_" in language:
        language, country = re.split("[-_]", language, maxsplit=1)
        return language.lower() + country.upper()

    language_length = 2
    if len(language) >= 3 and language[2].islower():
        language_length = 3
    return language[:language_length].lower() + language[language_length:].upper()


def normalize_basic(payload: Any) -> dict[str, Any]:
    basic = require_object(payload, "basic")
    if "BasicInfoToggle" not in basic:
        fail("basic.BasicInfoToggle", "缺少字段")
    toggle = parse_integer(basic["BasicInfoToggle"], "basic.BasicInfoToggle")
    if toggle not in (0, 1):
        fail("basic.BasicInfoToggle", "只能是 0 或 1")
    basic["BasicInfoToggle"] = toggle

    items = basic.get("BasicItems")
    if not isinstance(items, list):
        fail("basic.BasicItems", "必须是 JSON 数组")
    if toggle == 1 and not items:
        fail("basic.BasicItems", "BasicInfoToggle=1 时不能为空")

    seen_indexes: set[int] = set()
    for item_number, item in enumerate(items):
        item_path = f"basic.BasicItems[{item_number}]"
        item_object = require_object(item, item_path)
        for field in ("Title", "Summary", "Index"):
            if field not in item_object:
                fail(f"{item_path}.{field}", "缺少字段")
        require_string(item_object["Title"], f"{item_path}.Title")
        require_string(item_object["Summary"], f"{item_path}.Summary")
        index = parse_integer(item_object["Index"], f"{item_path}.Index")
        if index not in SUPPORTED_ITEM_INDEXES:
            fail(
                f"{item_path}.Index",
                "接口缓存当前只伪装 0、1、2、3、4、7；5（运行内存）和 6（型号）由 Settings 本地生成",
            )
        if index in seen_indexes:
            fail(f"{item_path}.Index", f"索引重复：{index}")
        seen_indexes.add(index)
        item_object["Index"] = index

    mishop = basic.get("Mishop")
    if mishop is not None:
        require_object(mishop, "basic.Mishop")
        if "ShowRedDot" in mishop:
            show_red_dot = mishop["ShowRedDot"]
            if isinstance(show_red_dot, (bool, int)):
                enabled = parse_boolean(
                    show_red_dot, "basic.Mishop.ShowRedDot"
                )
                mishop["ShowRedDot"] = "true" if enabled else "false"
            elif not isinstance(show_red_dot, str):
                fail("basic.Mishop.ShowRedDot", "必须是字符串或布尔值")
    return basic


def normalize_camera(payload: Any) -> dict[str, Any]:
    camera_response = require_object(payload, "camera")
    if "status" not in camera_response:
        fail("camera.status", "缺少字段")
    camera_response["status"] = parse_boolean(
        camera_response["status"], "camera.status"
    )

    data = require_object(camera_response.get("data"), "camera.data")
    if "BasicInfoToggle" not in data:
        fail("camera.data.BasicInfoToggle", "缺少字段")
    toggle = parse_integer(
        data["BasicInfoToggle"], "camera.data.BasicInfoToggle"
    )
    if toggle not in (0, 1):
        fail("camera.data.BasicInfoToggle", "只能是 0 或 1")
    data["BasicInfoToggle"] = toggle

    camera_values = require_object(data.get("camera"), "camera.data.camera")
    for field in ("front_camera", "rear_camera"):
        if field not in camera_values:
            fail(f"camera.data.camera.{field}", "缺少字段")
        require_string(
            camera_values[field], f"camera.data.camera.{field}"
        )
    return camera_response


def compact_json(value: Any, path: str) -> str:
    try:
        return json.dumps(
            value,
            ensure_ascii=False,
            separators=(",", ":"),
            allow_nan=False,
        )
    except (TypeError, ValueError) as error:
        fail(path, f"无法序列化为 JSON：{error}")


def render_xml(basic_json: str, camera_json: str, language: str) -> str:
    def text(value: str) -> str:
        return html.escape(value, quote=False)

    return (
        '<?xml version="1.0" encoding="utf-8" standalone="yes" ?>\n'
        '<map>\n'
        f'    <string name="basic_info_key">{text(basic_json)}</string>\n'
        f'    <string name="camera_info_key">{text(camera_json)}</string>\n'
        f'    <long name="device_params_last_update" value="{CACHE_TIMESTAMP_MS}" />\n'
        f'    <string name="device_params_last_lang">{text(language)}</string>\n'
        '</map>\n'
    )


def parse_payload(raw: str) -> tuple[str, str, str]:
    if not raw.strip():
        raise PayloadError(f"环境变量 {ENV_NAME} 为空")
    try:
        payload = json.loads(
            raw,
            parse_constant=lambda value: (_ for _ in ()).throw(
                PayloadError(f"顶层 JSON 不允许非有限数字：{value}")
            ),
        )
    except json.JSONDecodeError as error:
        raise PayloadError(
            f"环境变量 {ENV_NAME} 不是有效 JSON："
            f"第 {error.lineno} 行第 {error.colno} 列：{error.msg}"
        ) from error

    root = require_object(payload, "payload")
    language_value = get_one_alias(root, ("language", "langType"), "payload")
    basic_value = get_one_alias(root, ("basic", "basic_info"), "payload")
    camera_value = get_one_alias(root, ("camera", "camera_info"), "payload")
    language = normalize_language(language_value)
    basic = normalize_basic(basic_value)
    camera = normalize_camera(camera_value)
    return compact_json(basic, "basic"), compact_json(camera, "camera"), language


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--env", default=ENV_NAME, help=argparse.SUPPRESS)
    return parser


def main() -> int:
    args = build_parser().parse_args()
    try:
        raw = os.environ.get(args.env, "")
        basic_json, camera_json, language = parse_payload(raw)
        rendered = render_xml(basic_json, camera_json, language)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        with args.output.open("w", encoding="utf-8", newline="\n") as output:
            output.write(rendered)
    except (OSError, UnicodeError, PayloadError) as error:
        print(f"! 设备参数伪装配置：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
