#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "配置超声波屏下指纹"
std_print "坐标：使用目标设备流程提供的硬件参数，并按底包 PanelResolution 缩放"
std_print

fingerprint_properties_file="${ULTRASONIC_FP_PROPERTIES_FILE:-}"
if [[ -z "$fingerprint_properties_file" ]]; then
	err_print "缺少超声波指纹目标设备参数配置：ULTRASONIC_FP_PROPERTIES_FILE"
	exit 1
elif [[ -L "$fingerprint_properties_file" ]]; then
	err_print "超声波指纹参数配置不能是符号链接：$fingerprint_properties_file"
	exit 1
elif [[ ! -e "$fingerprint_properties_file" ]]; then
	err_print "超声波指纹参数配置不存在：$fingerprint_properties_file"
	exit 1
elif [[ ! -f "$fingerprint_properties_file" ]]; then
	err_print "超声波指纹参数配置不是普通文件：$fingerprint_properties_file"
	exit 1
fi
validate_prop_file "$fingerprint_properties_file"

read_fingerprint_parameter() {
	local property_name="$1"
	local property_value
	if ! property_value="$(read_prop_value "$property_name" "$fingerprint_properties_file")"; then
		err_print "超声波指纹参数配置缺少属性：$property_name"
		exit 1
	fi
	if [[ -z "$property_value" ]]; then
		err_print "超声波指纹参数配置的属性值为空：$property_name"
		exit 1
	fi
	printf '%s\n' "$property_value"
}

reference_width="$(read_fingerprint_parameter ultrasonic.fp.reference.width)"
reference_height="$(read_fingerprint_parameter ultrasonic.fp.reference.height)"
sensor_center_x="$(read_fingerprint_parameter ultrasonic.fp.sensor.center.x)"
sensor_center_y="$(read_fingerprint_parameter ultrasonic.fp.sensor.center.y)"
icon_width="$(read_fingerprint_parameter ultrasonic.fp.icon.width)"
icon_height="$(read_fingerprint_parameter ultrasonic.fp.icon.height)"
sensor_area_width="$(read_fingerprint_parameter ultrasonic.fp.sensor.area.width)"
sensor_area_height="$(read_fingerprint_parameter ultrasonic.fp.sensor.area.height)"
fingerprint_vendor="$(read_fingerprint_parameter ultrasonic.fp.vendor)"
fingerdown_delay_ms="$(read_fingerprint_parameter ultrasonic.fp.fingerdown.delay.ms)"

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
odm_build_prop="$project_dir/odm/build.prop"
display_resolution_config="$project_dir/odm/etc/sdm_display_resolution_extn.xml"
selinux_bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
selinux_policy_fragment="$patcher_dir/config/selinux_policy.cil.in"
vendor_selinux="$project_dir/vendor/etc/selinux"
vendor_policy="$vendor_selinux/vendor_sepolicy.cil"
vendor_versioned_policy="$vendor_selinux/plat_pub_versioned.cil"
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
for required_selinux_file in "$vendor_policy" "$vendor_versioned_policy"; do
	check_file_exists "$required_selinux_file"
	if [[ -L "$required_selinux_file" ]]; then
		err_print "指纹 SELinux 契约输入不能是符号链接：$required_selinux_file"
		exit 1
	fi
done
load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"
check_selinux_bundle_requirements "$project_dir"
if [[ "$SELINUX_BUNDLE_ACTIVE" != true ||
	${#SELINUX_BUNDLE_POLICY_FRAGMENTS[@]} != 1 ||
	${#SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]} != 2 ]]; then
	err_print "超声波指纹 SELinux bundle requirement 不完整"
	exit 1
fi
api_version="$(tr -d '[:space:]' < "$vendor_selinux/plat_sepolicy_vers.txt")"
if [[ ! "$api_version" =~ ^[0-9]+$ ]]; then
	err_print "指纹 SELinux bundle 无法识别目标 policy API：$api_version"
	exit 1
fi
if ! grep -Fqx '(type hal_fingerprint_oppo)' "$vendor_policy" ||
	! grep -Fqx '(type oppo_fingerprint_prop)' "$vendor_versioned_policy" ||
	! grep -Fqx "(typeattribute oppo_fingerprint_prop_${api_version})" "$vendor_versioned_policy" ||
	! grep -Fqx "(typeattribute powerctl_prop_${api_version})" "$vendor_versioned_policy" ||
	! grep -Eq "(^|[^A-Za-z0-9_])system_server_${api_version}([^A-Za-z0-9_]|$)" "$vendor_versioned_policy" ||
	! grep -Eq "(^|[^A-Za-z0-9_])platform_app_${api_version}([^A-Za-z0-9_]|$)" "$vendor_versioned_policy" ||
	! grep -Eq "(^|[^A-Za-z0-9_])zygote_${api_version}([^A-Za-z0-9_]|$)" "$vendor_versioned_policy"; then
	err_print "底包缺少超声波指纹 HAL、属性类型或版本化系统域契约"
	exit 1
fi
# shellcheck disable=SC2016 # ${API_VERSION} is expanded by selinux_merge, not this shell.
for expected_statement in \
	'(typeattributeset oppo_fingerprint_prop_${API_VERSION} (oppo_fingerprint_prop))' \
	'(type vendor_ultrasonic_fp_compat_prop)' \
	'(roletype object_r vendor_ultrasonic_fp_compat_prop)' \
	'(typeattributeset property_type (vendor_ultrasonic_fp_compat_prop))' \
	'(typeattributeset vendor_property_type (vendor_ultrasonic_fp_compat_prop))' \
	'(typeattributeset vendor_public_property_type (vendor_ultrasonic_fp_compat_prop))'; do
	if ! grep -Fqx "$expected_statement" "$selinux_policy_fragment"; then
		err_print "指纹 SELinux 片段缺少预期类型声明：$expected_statement"
		exit 1
	fi
done
if ! command -v python3 >/dev/null 2>&1; then
	err_print "缺少 Python 3，无法解析显示配置并换算指纹坐标"
	exit 1
fi

fingerprint_prop_patch="$(mktemp "$(get_config_path '.fix_ultrasonic_fingerprint.XXXXXX')")"
cleanup() {
	rm -f -- "$fingerprint_prop_patch"
}
trap cleanup EXIT

coordinate_summary="$(python3 - \
	"$display_resolution_config" \
	"$fingerprint_prop_patch" \
	"$reference_width" \
	"$reference_height" \
	"$sensor_center_x" \
	"$sensor_center_y" \
	"$icon_width" \
	"$icon_height" \
	"$sensor_area_width" \
	"$sensor_area_height" \
	"$fingerprint_vendor" \
	"$fingerdown_delay_ms" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


display_config_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

def positive_int(value, description):
    if value is None or not value.isdigit() or int(value) <= 0:
        raise ValueError(f"{description} 不是正整数：{value!r}")
    return int(value)


def non_negative_int(value, description):
    if not value.isdigit():
        raise ValueError(f"{description} 不是非负整数：{value!r}")
    return int(value)


try:
    reference_width = positive_int(sys.argv[3], "参考分辨率宽度")
    reference_height = positive_int(sys.argv[4], "参考分辨率高度")
    reference_sensor_center = (
        non_negative_int(sys.argv[5], "参考传感器中心 X"),
        non_negative_int(sys.argv[6], "参考传感器中心 Y"),
    )
    reference_icon_size = (
        positive_int(sys.argv[7], "参考图标宽度"),
        positive_int(sys.argv[8], "参考图标高度"),
    )
    reference_target_size = (
        positive_int(sys.argv[9], "参考识别区宽度"),
        positive_int(sys.argv[10], "参考识别区高度"),
    )
    fingerdown_delay_ms = non_negative_int(sys.argv[12], "按下延迟")
except ValueError as error:
    raise SystemExit(f"超声波指纹参数无效：{error}")

fingerprint_vendor = sys.argv[11]
if not re.fullmatch(r"[A-Za-z0-9_.-]+", fingerprint_vendor):
    raise SystemExit(
        f"超声波指纹参数无效：厂商协议值包含非法字符：{fingerprint_vendor!r}"
    )
if (
    reference_target_size[0] < reference_icon_size[0]
    or reference_target_size[1] < reference_icon_size[1]
):
    raise SystemExit("超声波指纹参数无效：参考识别区不能小于参考图标")


def validate_reference_region(center, size, limit, description):
    start = center - size // 2
    end = start + size
    if start < 0 or end > limit:
        raise SystemExit(f"超声波指纹参数无效：{description}超出参考分辨率")


validate_reference_region(
    reference_sensor_center[0], reference_icon_size[0], reference_width, "图标横向区域"
)
validate_reference_region(
    reference_sensor_center[1], reference_icon_size[1], reference_height, "图标纵向区域"
)
validate_reference_region(
    reference_sensor_center[0],
    reference_target_size[0],
    reference_width,
    "识别区横向区域",
)
validate_reference_region(
    reference_sensor_center[1],
    reference_target_size[1],
    reference_height,
    "识别区纵向区域",
)


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
    f"persist.vendor.sys.fp.vendor={fingerprint_vendor}",
    f"persist.vendor.sys.fp.fod.location.X_Y={location_x},{location_y}",
    f"persist.vendor.sys.fp.fod.size.width_height={size_width},{size_height}",
    "persist.vendor.sys.fp.fod.us.target="
    f"{target_left},{target_top},{target_right},{target_bottom}",
    f"persist.vendor.sys.fp.fod.delay.fingerdown.ms={fingerdown_delay_ms}",
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
