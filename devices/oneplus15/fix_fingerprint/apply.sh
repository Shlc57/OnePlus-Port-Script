#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "修复一加 15 超声波指纹"
std_print "坐标：按一加 15 实机 HAL 的传感器中心与图标尺寸适配 PanelResolution"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
odm_build_prop="$project_dir/odm/build.prop"
display_resolution_config="$project_dir/odm/etc/sdm_display_resolution_extn.xml"
prop_patch_ready=1
if [[ -L "$odm_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$odm_build_prop"
	exit 1
elif [[ ! -e "$odm_build_prop" ]]; then
	warn_print "指纹属性目标不存在，跳过：${odm_build_prop#"$project_dir"/}"
	prop_patch_ready=0
elif [[ ! -f "$odm_build_prop" ]]; then
	err_print "指纹属性目标不是普通文件：$odm_build_prop"
	exit 1
fi
if [[ -L "$display_resolution_config" ]]; then
	err_print "指纹属性坐标来源不能是符号链接：$display_resolution_config"
	exit 1
elif [[ ! -e "$display_resolution_config" ]]; then
	warn_print "指纹属性坐标来源不存在，跳过：${display_resolution_config#"$project_dir"/}"
	prop_patch_ready=0
elif [[ ! -f "$display_resolution_config" ]]; then
	err_print "指纹属性坐标来源不是普通文件：$display_resolution_config"
	exit 1
fi
if (( prop_patch_ready == 0 )); then
	std_print "处理完成"
	exit 0
fi
if ! command -v python3 >/dev/null 2>&1; then
	err_print "缺少 Python 3，无法解析显示配置并换算指纹坐标"
	exit 1
fi

fingerprint_prop_patch="$(mktemp)"
cleanup() {
	rm -f -- "$fingerprint_prop_patch"
}
trap cleanup EXIT

coordinate_summary="$(python3 - "$display_resolution_config" "$fingerprint_prop_patch" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


display_config_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

reference_width = 1272
reference_height = 2772
# 一加 15 实机 HAL：sensorlocation=636::2048，iconsize=195。
reference_sensor_center = (636, 2048)
reference_icon_size = (195, 195)
# 识别区保持一加 13 示例中 208x228 相对 184x184 图标的扩大比例。
reference_target_size = (220, 242)


def positive_int(value, description):
    if value is None or not value.isdigit() or int(value) <= 0:
        raise ValueError(f"{description} 不是正整数：{value!r}")
    return int(value)


def scale_half_up(value, source_size, target_size):
    return (2 * value * target_size + source_size) // (2 * source_size)


try:
    display_root = ET.parse(display_config_path).getroot()
except (OSError, ET.ParseError) as error:
    raise SystemExit(f"解析显示配置失败：{display_config_path}：{error}")

panel_resolutions = []
for panel in display_root.iter("PanelResolution"):
    try:
        panel_resolution = (
            positive_int(panel.get("width"), "PanelResolution width"),
            positive_int(panel.get("height"), "PanelResolution height"),
        )
    except ValueError as error:
        raise SystemExit(f"显示配置无效：{display_config_path}：{error}")
    if panel_resolution not in panel_resolutions:
        panel_resolutions.append(panel_resolution)

if not panel_resolutions:
    raise SystemExit(f"显示配置中没有 PanelResolution：{display_config_path}")
if len(panel_resolutions) != 1:
    resolution_text = "、".join(
        f"{width}x{height}" for width, height in panel_resolutions
    )
    raise SystemExit(
        "显示配置包含多组不同的原生分辨率，无法唯一换算指纹坐标："
        f"{resolution_text}"
    )

panel_width, panel_height = panel_resolutions[0]
sensor_center_x = scale_half_up(
    reference_sensor_center[0], reference_width, panel_width
)
sensor_center_y = scale_half_up(
    reference_sensor_center[1], reference_height, panel_height
)
size_width = scale_half_up(reference_icon_size[0], reference_width, panel_width)
size_height = scale_half_up(reference_icon_size[1], reference_height, panel_height)
target_width = scale_half_up(reference_target_size[0], reference_width, panel_width)
target_height = scale_half_up(reference_target_size[1], reference_height, panel_height)

location_x = sensor_center_x - size_width // 2
location_y = sensor_center_y - size_height // 2
target_left = sensor_center_x - target_width // 2
target_top = sensor_center_y - target_height // 2
target_right = target_left + target_width
target_bottom = target_top + target_height

if size_width <= 0 or size_height <= 0:
    raise SystemExit("换算后的指纹图标尺寸无效")
if not (
    0 <= location_x
    and location_x + size_width <= panel_width
    and 0 <= location_y
    and location_y + size_height <= panel_height
):
    raise SystemExit("换算后的指纹图标区域超出面板范围")
if not (0 <= target_left < target_right <= panel_width):
    raise SystemExit("换算后的超声波指纹横向识别区域无效")
if not (0 <= target_top < target_bottom <= panel_height):
    raise SystemExit("换算后的超声波指纹纵向识别区域无效")

properties = (
    "ro.hardware.fp.fod.c=true",
    "ro.hardware.fp.fod=true",
    "persist.vendor.sys.fp.vendor=oplus",
    f"persist.vendor.sys.fp.fod.location.X_Y={location_x},{location_y}",
    f"persist.vendor.sys.fp.fod.size.width_height={size_width},{size_height}",
    "persist.vendor.sys.fp.fod.us.target="
    f"{target_left},{target_top},{target_right},{target_bottom}",
    "persist.vendor.sys.fp.fod.delay.fingerdown.ms=20",
)

try:
    output_path.write_text("\n".join(properties) + "\n", encoding="utf-8")
except OSError as error:
    raise SystemExit(f"写入临时指纹属性失败：{output_path}：{error}")

print(
    f"面板 {panel_width}x{panel_height}；"
    f"传感器中心 {sensor_center_x},{sensor_center_y}；"
    f"图标 {location_x},{location_y}；"
    f"尺寸 {size_width},{size_height}；"
    f"识别区域 {target_left},{target_top},{target_right},{target_bottom}"
)
PY
)"

validate_prop_file "$fingerprint_prop_patch"
merge_prop_file "$fingerprint_prop_patch" "$odm_build_prop"

std_print "✅ 已更新：odm/build.prop"
std_print "✅ $coordinate_summary"
std_print "处理完成"
