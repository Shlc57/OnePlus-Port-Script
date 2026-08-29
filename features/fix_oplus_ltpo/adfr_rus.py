#!/usr/bin/env python3
"""Validate an Oplus ADFR RUS XML file and emit its vendor int[225] payload.

This is deliberately a build-time tool.  The target system only receives the
same packed values that the original Oplus DisplayManager extension sends to
the panel-feature AIDL service; it does not parse arbitrary XML at boot.
"""

from __future__ import annotations

import argparse
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from typing import Final


PAYLOAD_LENGTH: Final = 225
FEATURE_RUS_UPDATE: Final = 234
SERVICE_NAME: Final = (
    "vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature/default"
)
SERVICE_DESCRIPTOR: Final = "vendor.oplus.hardware.displaypanelfeature.IDisplayPanelFeature"
# This marker identifies the helper implementation, not the XML payload.  The
# payload is protocol data and may legitimately change when the project asset
# changes; it must not be treated as a base/original file identity.
LOADER_MARKER: Final = "OPLUS_ADFR_RUS_LOADER_V2"
ASYNC_MARKER: Final = "OPLUS_ADFR_RUS_LOADER_ASYNC_V1"

SCALAR_OFFSETS: Final = {
    "enable": 2,
    "debug_enable": 3,
    "sensor_enable": 4,
    "panelnit_enable": 5,
    "gray_enable": 6,
    "tracking_switch": 7,
    "gray_cal": 8,
    "sampleInterval": 9,
    "sensor_inlux": 10,
    "sensor_outlux": 11,
    "sensor_gaptime": 12,
    "fullscreen_aod": 14,
    "reserve_mode": 15,
}

# The Oplus XML parser reserves index 0 of every vector for the number of
# values parsed from XML, then copies the actual values from index 1.  These
# capacities therefore include the count field; they are not plain value-array
# capacities.  The panel-feature -> SDM bridge retains this layout.
ARRAY_LAYOUT: Final = (
    (18, "panelnit_level", 6),
    (24, "Y_l_level", 6),
    (30, "Y_h_level", 6),
    (36, "sum_level", 6),
    (42, "max_level", 6),
    (48, "minfps120_level", 13),
    (61, "minfps90_level", 13),
    (74, "minfps60_level", 13),
    (87, "aod_panelnit_level", 6),
    (93, "aod_Y_l_level", 6),
    (99, "aod_Y_h_level", 6),
    (105, "aod_sum_level", 6),
    (111, "aod_max_level", 6),
    (117, "aod_minfps120_level", 13),
    (130, "aod_minfps90_level", 13),
    (143, "aod_minfps60_level", 13),
    (156, "reserve_panelnit_level", 6),
    (162, "reserve_Y_l_level", 6),
    (168, "reserve_Y_h_level", 6),
    (174, "reserve_sum_level", 6),
    (180, "reserve_max_level", 6),
    (186, "reserve_minfps_level1", 13),
    (199, "reserve_minfps_level2", 13),
    (212, "reserve_minfps_level3", 13),
)

INTEGER_RE: Final = re.compile(r"^(?:0|[1-9][0-9]*)$")


class RusConfigError(ValueError):
    """Raised when the device supplied RUS input cannot be represented safely."""


def _parse_nonnegative_integer(value: str | None, description: str) -> int:
    if value is None:
        raise RusConfigError(f"缺少 {description}")
    normalized = value.strip()
    if not INTEGER_RE.fullmatch(normalized):
        raise RusConfigError(f"{description} 不是非负十进制整数：{value!r}")
    parsed = int(normalized)
    if parsed > 0x7FFFFFFF:
        raise RusConfigError(f"{description} 超出 int32 范围：{parsed}")
    return parsed


def _parse_vector(value: str | None, description: str, capacity: int) -> list[int]:
    if value is None:
        raise RusConfigError(f"缺少 {description}")
    pieces = value.split()
    if not pieces:
        raise RusConfigError(f"{description} 不能为空")
    if capacity < 2:
        raise AssertionError(f"invalid vector capacity for {description}: {capacity}")
    max_values = capacity - 1
    if len(pieces) > max_values:
        raise RusConfigError(
            f"{description} 数量超出原厂数组容量：{len(pieces)} > {max_values}"
        )
    values = [
        _parse_nonnegative_integer(piece, f"{description}[{index}]")
        for index, piece in enumerate(pieces)
    ]
    # Match OplusHwDisplayXmlParseCommon.splitStringToMultipleIntegers():
    # numbers[0] = parts.length; numbers[i + 1] = parsed XML value.
    return [len(values), *values]


def build_payload(xml_path: Path) -> list[int]:
    """Return the exact Oplus `updateAdfrXmlConfig()` int[225] representation."""

    try:
        tree = ET.parse(xml_path)
    except (ET.ParseError, OSError) as error:
        raise RusConfigError(f"无法读取 ADFR RUS XML：{xml_path}：{error}") from error

    root = tree.getroot()
    if root.tag != "root":
        raise RusConfigError(f"ADFR RUS XML 根标签必须是 root：{xml_path}")

    versions = root.findall("./oplsadfrCfg/version")
    if len(versions) != 1:
        raise RusConfigError(
            f"ADFR RUS XML 必须有唯一 oplsadfrCfg/version：实际 {len(versions)} 个"
        )
    version = _parse_nonnegative_integer(versions[0].text, "version")
    if version == 0:
        raise RusConfigError("ADFR RUS XML version 必须大于零")

    modes = root.findall("./oplsadfrCfg/mode[@name='adfr2minfps_config']")
    if len(modes) != 1:
        raise RusConfigError(
            "ADFR RUS XML 必须有唯一 mode name=adfr2minfps_config："
            f"实际 {len(modes)} 个"
        )
    mode = modes[0]
    if mode.findall(".//type") or mode.findall(".//panelid"):
        raise RusConfigError(
            "当前最小 loader 只支持单面板（panelId=0）RUS XML，不能包含 type/panelid"
        )

    values: dict[str, str] = {}
    for child in mode:
        if len(child):
            raise RusConfigError(f"ADFR mode 不支持嵌套标签：{child.tag}")
        if child.tag in values:
            raise RusConfigError(f"ADFR mode 标签重复：{child.tag}")
        values[child.tag] = child.text or ""

    allowed_tags = set(SCALAR_OFFSETS) | {name for _, name, _ in ARRAY_LAYOUT}
    unexpected = sorted(set(values) - allowed_tags)
    if unexpected:
        raise RusConfigError("ADFR mode 包含未支持标签：" + ", ".join(unexpected))

    payload = [0] * PAYLOAD_LENGTH
    payload[0] = 1  # selector: complete RUS update
    payload[1] = version
    # Original Oplus parser leaves mPanelId at zero when XML has no panelid tag.
    payload[13] = 0

    for name, offset in SCALAR_OFFSETS.items():
        payload[offset] = _parse_nonnegative_integer(values.get(name), name)

    for offset, name, capacity in ARRAY_LAYOUT:
        vector = _parse_vector(values.get(name), name, capacity)
        payload[offset : offset + len(vector)] = vector

    if len(payload) != PAYLOAD_LENGTH:
        raise AssertionError("internal ADFR payload length mismatch")
    return payload


def emit_smali_method(payload: list[int]) -> str:
    """Emit a failure-tolerant AIDL transaction-2 helper method.

    The original Oplus path reaches the panel-feature call from a queued
    display-feature handler.  Keep the sender itself self-contained, while
    the JAR patcher wraps its invocation in a Handler Runnable so boot-complete
    ordering matches that asynchronous boundary.
    """
    array_data = "\n".join(f"        0x{value:x}" for value in payload)
    return f'''# OPLUS_ADFR_RUS_LOADER_BEGIN
.method public sendOplusAdfrRusConfig()V
    .locals 6

    const/16 v0, 0xe1

    new-array v0, v0, [I

    fill-array-data v0, :array_0

    const-string/jumbo v4, "{LOADER_MARKER}"

    const-string/jumbo v5, "{ASYNC_MARKER}"

    const-string/jumbo v1, "{SERVICE_NAME}"

    invoke-static {{v1}}, Landroid/os/ServiceManager;->getService(Ljava/lang/String;)Landroid/os/IBinder;

    move-result-object v1

    if-nez v1, :cond_service_ready

    const-string v0, "DisplayManagerServiceImpl"

    const-string/jumbo v1, "OPLUS_ADFR_RUS_SKIP: panel-feature service unavailable"

    invoke-static {{v0, v1}}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I

    return-void

    :cond_service_ready
    invoke-static {{}}, Landroid/os/Parcel;->obtain()Landroid/os/Parcel;

    move-result-object v2

    invoke-static {{}}, Landroid/os/Parcel;->obtain()Landroid/os/Parcel;

    move-result-object v3

    :try_start_0
    const-string/jumbo v4, "{SERVICE_DESCRIPTOR}"

    invoke-virtual {{v2, v4}}, Landroid/os/Parcel;->writeInterfaceToken(Ljava/lang/String;)V

    const/16 v4, 0xea

    invoke-virtual {{v2, v4}}, Landroid/os/Parcel;->writeInt(I)V

    invoke-virtual {{v2, v0}}, Landroid/os/Parcel;->writeIntArray([I)V

    const/4 v4, 0x2

    const/4 v5, 0x0

    invoke-interface {{v1, v4, v2, v3, v5}}, Landroid/os/IBinder;->transact(ILandroid/os/Parcel;Landroid/os/Parcel;I)Z

    move-result v4

    if-eqz v4, :cond_recycle

    invoke-virtual {{v3}}, Landroid/os/Parcel;->readException()V

    const-string v0, "DisplayManagerServiceImpl"

    const-string/jumbo v1, "OPLUS_ADFR_RUS_SENT"

    invoke-static {{v0, v1}}, Landroid/util/Slog;->i(Ljava/lang/String;Ljava/lang/String;)I

    goto :goto_recycle

    :cond_recycle
    const-string v0, "DisplayManagerServiceImpl"

    const-string/jumbo v1, "OPLUS_ADFR_RUS_SKIP: transaction unavailable"

    invoke-static {{v0, v1}}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;)I

    :try_end_0
    goto :goto_recycle

    :catch_0
    move-exception v4

    const-string v0, "DisplayManagerServiceImpl"

    const-string/jumbo v1, "OPLUS_ADFR_RUS_SKIP: panel-feature call failed"

    invoke-static {{v0, v1, v4}}, Landroid/util/Slog;->w(Ljava/lang/String;Ljava/lang/String;Ljava/lang/Throwable;)I

    :goto_recycle
    invoke-virtual {{v2}}, Landroid/os/Parcel;->recycle()V

    invoke-virtual {{v3}}, Landroid/os/Parcel;->recycle()V

    return-void

    :array_0
    .array-data 4
{array_data}
    .end array-data

    .catch Ljava/lang/Exception; {{:try_start_0 .. :try_end_0}} :catch_0
.end method
# OPLUS_ADFR_RUS_LOADER_END
'''


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--validate", metavar="XML", type=Path)
    action.add_argument("--smali-method", metavar="XML", type=Path)
    args = parser.parse_args()

    xml_path = args.validate or args.smali_method
    assert xml_path is not None
    try:
        payload = build_payload(xml_path)
    except RusConfigError as error:
        print(f"! {error}", file=sys.stderr)
        return 1

    if args.validate is not None:
        # This is the fixed panel-feature protocol vector length, not a file
        # size or an identity check for either OTA input package.
        print(f"length={len(payload)}")
    else:
        print(emit_smali_method(payload), end="")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
