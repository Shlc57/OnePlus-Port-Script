#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "修复一加 15 刷新率与分辨率切换"
std_print "刷新率：60 / 90 / 120 / 144 / 165Hz"
std_print "分辨率：跟随底包 sdm_display_resolution_extn.xml"
std_print

# init_port_env 注入当前移植工程根目录。
# shellcheck disable=SC2154
display_resolution_config="$project_dir/odm/etc/sdm_display_resolution_extn.xml"
device_features_dir="$project_dir/product/etc/device_features"
settings_apk="$project_dir/system_ext/priv-app/Settings/Settings.apk"
settings_oat_dir="$project_dir/system_ext/priv-app/Settings/oat"
# init_port_env 注入补丁仓库根目录。
# shellcheck disable=SC2154
settings_patcher="$port_dir/common/settings_apk_patcher.sh"

device_code=""
device_prop_files=(
	"$project_dir/odm/etc/build.prop"
	"$project_dir/odm/build.prop"
	"$project_dir/mi_odm/etc/build.prop"
)
for prop_file in "${device_prop_files[@]}"; do
	if [[ -L "$prop_file" ]]; then
		err_print "不支持从符号链接读取属性：$prop_file"
		exit 1
	elif [[ ! -e "$prop_file" ]]; then
		warn_print "设备代号属性来源不存在，跳过：${prop_file#"$project_dir"/}"
		continue
	elif [[ ! -f "$prop_file" ]]; then
		err_print "设备代号属性来源不是普通文件：$prop_file"
		exit 1
	fi
	if grep -Eq '^[[:space:]]*ro\.product\.odm\.device[[:space:]]*=' "$prop_file"; then
		prop_device_code="$(read_prop_value ro.product.odm.device "$prop_file")"
		if [[ -z "$prop_device_code" ]]; then
			warn_print "设备代号属性值为空，跳过：${prop_file#"$project_dir"/}"
			continue
		fi
		if [[ -z "$device_code" ]]; then
			device_code="$prop_device_code"
		elif [[ "$device_code" != "$prop_device_code" ]]; then
			err_print "设备代号来源不一致：$device_code / $prop_device_code"
			exit 1
		fi
	else
		warn_print "设备代号属性不存在，跳过：${prop_file#"$project_dir"/} 中的 ro.product.odm.device"
	fi
done

if [[ -z "$device_code" ]]; then
	warn_print "无法从 odm/mi_odm build.prop 读取 ro.product.odm.device，跳过刷新率与分辨率切换"
	std_print "处理完成"
	exit 0
fi
if [[ ! "$device_code" =~ ^[A-Za-z0-9_.-]+$ ]]; then
	err_print "设备代号无效：$device_code"
	exit 1
fi

for part_name in odm product system_ext; do
	check_part_exists "$part_name"
done

device_feature_xml="$device_features_dir/$device_code.xml"
feature_patch_ready=1
if [[ -L "$device_features_dir" ]]; then
	err_print "device_features 目录不能是符号链接：$device_features_dir"
	exit 1
elif [[ ! -e "$device_features_dir" ]]; then
	warn_print "device_features 目录不存在，跳过机型 XML 子步骤：${device_features_dir#"$project_dir"/}"
	feature_patch_ready=0
elif [[ ! -d "$device_features_dir" ]]; then
	err_print "device_features 路径不是普通目录：$device_features_dir"
	exit 1
elif [[ -L "$device_feature_xml" ]]; then
	err_print "不支持直接修改符号链接：$device_feature_xml"
	exit 1
elif [[ ! -e "$device_feature_xml" ]]; then
	warn_print "待修改的刷新率机型配置不存在，跳过：${device_feature_xml#"$project_dir"/}"
	feature_patch_ready=0
elif [[ ! -f "$device_feature_xml" ]]; then
	err_print "待修改的刷新率机型配置不是普通文件：$device_feature_xml"
	exit 1
fi

settings_patch_ready=1
if [[ -L "$settings_apk" ]]; then
	err_print "不支持修改符号链接 APK：$settings_apk"
	exit 1
elif [[ ! -e "$settings_apk" ]]; then
	warn_print "待修补的 Settings.apk 不存在，跳过分辨率高度子步骤：${settings_apk#"$project_dir"/}"
	settings_patch_ready=0
elif [[ ! -f "$settings_apk" ]]; then
	err_print "待修补的 Settings.apk 不是普通文件：$settings_apk"
	exit 1
fi

if (( feature_patch_ready == 1 )); then
	check_file_exists "$display_resolution_config"
	if ! command -v python3 >/dev/null 2>&1; then
		err_print "缺少 Python 3，无法安全修改 device_features XML"
		exit 1
	fi
fi
if (( settings_patch_ready == 1 )); then
	check_file_exists "$settings_patcher"
	check_file_exists "$(get_part_contexts_path system_ext)"
	check_file_exists "$(get_part_fsconfig_path system_ext)"
	check_partition_metadata_tool >/dev/null
fi
if (( feature_patch_ready == 0 && settings_patch_ready == 0 )); then
	std_print "处理完成"
	exit 0
fi

if (( feature_patch_ready == 1 )); then
temporary_xml="$(mktemp "${device_feature_xml}.tmp.XXXXXX")"
cleanup() {
	rm -f -- "$temporary_xml"
}
trap cleanup EXIT

resolution_summary="$(python3 - "$device_feature_xml" "$display_resolution_config" "$temporary_xml" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


feature_path = Path(sys.argv[1])
display_config_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])
supported_fps = (165, 144, 120, 90, 60)


def positive_int(value, description):
    if value is None or not value.isdigit() or int(value) <= 0:
        raise ValueError(f"{description} 不是正整数：{value!r}")
    return int(value)


try:
    display_root = ET.parse(display_config_path).getroot()
except (OSError, ET.ParseError) as error:
    raise SystemExit(f"解析显示配置失败：{display_config_path}：{error}")

supported_widths = []
seen_widths = set()
panel_resolutions = []
for panel in display_root.iter("PanelResolution"):
    try:
        panel_width = positive_int(panel.get("width"), "PanelResolution width")
        panel_height = positive_int(panel.get("height"), "PanelResolution height")
    except ValueError as error:
        raise SystemExit(f"显示配置无效：{display_config_path}：{error}")
    panel_resolutions.append((panel_width, panel_height))
    if panel_width not in seen_widths:
        supported_widths.append(panel_width)
        seen_widths.add(panel_width)

    for scaling in panel.iter("ScalingResolution"):
        try:
            scaling_width = positive_int(scaling.get("w"), "ScalingResolution w")
            positive_int(scaling.get("h"), "ScalingResolution h")
        except ValueError as error:
            raise SystemExit(f"显示配置无效：{display_config_path}：{error}")
        if scaling_width not in seen_widths:
            supported_widths.append(scaling_width)
            seen_widths.add(scaling_width)

if not panel_resolutions:
    raise SystemExit(f"显示配置中没有 PanelResolution：{display_config_path}")

try:
    original_text = feature_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"读取机型配置失败：{feature_path}：{error}")

newline = "\r\n" if "\r\n" in original_text else "\n"


def replace_named_integer(text, name, value):
    pattern = re.compile(
        rf'(?m)^([ \t]*)<integer name="{re.escape(name)}">[^<]*</integer>[ \t]*$'
    )

    def replacement(match):
        return f'{match.group(1)}<integer name="{name}">{value}</integer>'

    updated, count = pattern.subn(replacement, text)
    if count != 1:
        raise SystemExit(f"机型配置中的 {name} 数量应为 1，实际为 {count}：{feature_path}")
    return updated


def array_block(indent, name, values):
    lines = [f'{indent}<integer-array name="{name}">']
    lines.extend(f"{indent}    <item>{value}</item>" for value in values)
    lines.append(f"{indent}</integer-array>")
    return newline.join(lines)


def replace_named_array(text, name, values, required):
    pattern = re.compile(
        rf'(?ms)^([ \t]*)<integer-array name="{re.escape(name)}">.*?</integer-array>[ \t]*$'
    )

    def replacement(match):
        return array_block(match.group(1), name, values)

    updated, count = pattern.subn(replacement, text)
    if count > 1 or (required and count != 1):
        expected = "1" if required else "0 或 1"
        raise SystemExit(
            f"机型配置中的 {name} 数量应为 {expected}，实际为 {count}：{feature_path}"
        )
    return updated, count


updated_text = replace_named_integer(original_text, "smart_fps_value", supported_fps[0])
updated_text, _ = replace_named_array(updated_text, "fpsList", supported_fps, True)
updated_text, resolution_array_count = replace_named_array(
    updated_text, "screen_resolution_supported", supported_widths, False
)

if resolution_array_count == 0:
    resolution_block = array_block("    ", "screen_resolution_supported", supported_widths)
    display_marker = re.compile(r'(?m)^[ \t]*<!-- Display BEGIN -->[ \t]*$')
    marker_matches = list(display_marker.finditer(updated_text))
    if len(marker_matches) == 1:
        marker = marker_matches[0]
        updated_text = (
            updated_text[: marker.end()]
            + newline
            + resolution_block
            + updated_text[marker.end() :]
        )
    else:
        end_features = re.compile(r'(?m)^[ \t]*</features>[ \t]*$')
        end_matches = list(end_features.finditer(updated_text))
        if len(end_matches) != 1:
            raise SystemExit(
                "无法唯一定位 Display BEGIN 或 </features>，拒绝插入分辨率配置："
                f"{feature_path}"
            )
        end_match = end_matches[0]
        updated_text = (
            updated_text[: end_match.start()]
            + resolution_block
            + newline
            + updated_text[end_match.start() :]
        )

try:
    ET.fromstring(updated_text)
except ET.ParseError as error:
    raise SystemExit(f"修改后的机型配置 XML 无效：{feature_path}：{error}")

try:
    with output_path.open("w", encoding="utf-8", newline="") as output:
        output.write(updated_text)
except OSError as error:
    raise SystemExit(f"写入临时机型配置失败：{output_path}：{error}")

panel_text = ", ".join(f"{width}x{height}" for width, height in panel_resolutions)
width_text = ", ".join(str(width) for width in supported_widths)
print(f"面板 {panel_text}；可切换宽度 {width_text}")
PY
)"
fi

if (( settings_patch_ready == 1 )); then
	bash "$settings_patcher" screen-resolution "$settings_apk"
	remove_path_if_exists "$settings_oat_dir"
	remove_part_metadata_prefix system_ext priv-app/Settings/oat
fi
if (( feature_patch_ready == 1 )); then
	_install_generated_file "$temporary_xml" "$device_feature_xml"
fi

if (( feature_patch_ready == 1 )); then
	std_print "✅ 已更新：product/etc/device_features/$device_code.xml"
	std_print "✅ 刷新率列表：165、144、120、90、60Hz"
	std_print "✅ 分辨率来源：${display_resolution_config#"$project_dir/"}（$resolution_summary）"
fi
if (( settings_patch_ready == 1 )); then
	std_print "✅ Settings 高度计算：优先匹配显示 supported mode 的真实宽高，1080 宽不再截断为 2353"
fi
std_print "处理完成"
