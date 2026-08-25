#!/bin/bash
set -Eeuo pipefail

init_port_env "${1:-}"

std_print "修复一加 15 DC/PWM 与超高刷新率切换"
std_print "关闭 Pro：完整显示 60 / 90 / 120 / 144 / 165Hz，由面板按刷新率选择 DC/PWM；开启 Pro：请求全局 PWM"
std_print

# init_port_env 注入当前移植工程根目录和补丁仓库根目录。
# shellcheck disable=SC2154
feature_xml="$PORT_SOURCE_DEVICE_FEATURE_FILE"
# shellcheck disable=SC2154
misettings_apk="$project_dir/product/priv-app/MISettings/MISettings.apk"
misettings_oat_dir="$project_dir/product/priv-app/MISettings/oat"
# shellcheck disable=SC2154
misettings_patcher="$port_dir/devices/oneplus15/fix_refresh_rate_switch/patch_misettings_dc_refresh.sh"
settings_apk="$project_dir/system_ext/priv-app/Settings/Settings.apk"
settings_oat_dir="$project_dir/system_ext/priv-app/Settings/oat"
# shellcheck disable=SC2154
settings_patcher="$port_dir/devices/oneplus15/fix_refresh_rate_switch/patch_settings_dc_refresh.sh"

check_part_exists product
check_part_exists system_ext

feature_ready=1
if [[ -z "$feature_xml" ]]; then
	warn_print "移植前未识别原包机型 XML，跳过 DC 互斥 FeatureParser 子步骤"
	feature_ready=0
elif [[ -L "$feature_xml" ]]; then
	err_print "不支持直接修改符号链接：$feature_xml"
	exit 1
elif [[ ! -e "$feature_xml" ]]; then
	warn_print "机型 XML 不存在，跳过 DC 互斥 FeatureParser 子步骤：${feature_xml#"$project_dir"/}"
	feature_ready=0
elif [[ ! -f "$feature_xml" ]]; then
	err_print "机型 XML 不是普通文件：$feature_xml"
	exit 1
fi

misettings_ready=1
if [[ -L "$misettings_apk" ]]; then
	err_print "不支持修改符号链接 APK：$misettings_apk"
	exit 1
elif [[ ! -e "$misettings_apk" ]]; then
	warn_print "MISettings.apk 不存在，跳过 DC/PWM 互斥子步骤：${misettings_apk#"$project_dir"/}"
	misettings_ready=0
elif [[ ! -f "$misettings_apk" ]]; then
	err_print "MISettings.apk 不是普通文件：$misettings_apk"
	exit 1
fi

settings_ready=1
if [[ -L "$settings_apk" ]]; then
	err_print "不支持修改符号链接 Settings.apk：$settings_apk"
	exit 1
elif [[ ! -e "$settings_apk" ]]; then
	warn_print "Settings.apk 不存在，跳过 DC 切换回退子步骤：${settings_apk#"$project_dir"/}"
	settings_ready=0
elif [[ ! -f "$settings_apk" ]]; then
	err_print "Settings.apk 不是普通文件：$settings_apk"
	exit 1
fi

if (( misettings_ready == 1 )); then
	check_file_exists "$misettings_patcher"
	check_file_exists "$(get_part_contexts_path product)"
	check_file_exists "$(get_part_fsconfig_path product)"
	check_partition_metadata_tool >/dev/null
fi
if (( settings_ready == 1 )); then
	check_file_exists "$settings_patcher"
	check_file_exists "$(get_part_contexts_path system_ext)"
	check_file_exists "$(get_part_fsconfig_path system_ext)"
	check_partition_metadata_tool >/dev/null
fi

temporary_xml=''
cleanup() {
	if [[ -n "$temporary_xml" ]]; then
		rm -f -- "$temporary_xml"
	fi
}
trap cleanup EXIT

if (( feature_ready == 1 )); then
	temporary_xml="$(mktemp "${feature_xml}.tmp.XXXXXX")"
	PYTHONDONTWRITEBYTECODE=1 python3 - "$feature_xml" "$temporary_xml" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])

try:
    text = source_path.read_text(encoding="utf-8")
except (OSError, UnicodeError) as error:
    raise SystemExit(f"读取机型 XML 失败：{source_path}：{error}")

newline = "\r\n" if "\r\n" in text else "\n"
guard = re.compile(
    r'(?m)^(?P<indent>[ \t]*)<bool name="dc_backlight_fps_incompatible">[^<]*</bool>[ \t]*$'
)
updated, count = guard.subn(
    lambda match: f'{match.group("indent")}<bool name="dc_backlight_fps_incompatible">true</bool>',
    text,
)
if count > 1:
    raise SystemExit(
        f"dc_backlight_fps_incompatible 数量应为 0 或 1，实际为 {count}：{source_path}"
    )
if count == 0:
    support = re.compile(
        r'(?m)^(?P<indent>[ \t]*)<bool name="support_dc_backlight">[^<]*</bool>[ \t]*$'
    )
    matches = list(support.finditer(text))
    if len(matches) != 1:
        raise SystemExit(
            "无法唯一定位 support_dc_backlight，拒绝插入 dc_backlight_fps_incompatible："
            f"{source_path}"
        )
    marker = matches[0]
    updated = (
        text[: marker.end()]
        + newline
        + f'{marker.group("indent")}<bool name="dc_backlight_fps_incompatible">true</bool>'
        + text[marker.end() :]
    )

try:
    ET.fromstring(updated)
except ET.ParseError as error:
    raise SystemExit(f"修改后的机型 XML 无效：{source_path}：{error}")

try:
    output_path.write_text(updated, encoding="utf-8", newline="")
except OSError as error:
    raise SystemExit(f"写入临时机型 XML 失败：{output_path}：{error}")
PY
fi

if (( misettings_ready == 1 )); then
	bash "$misettings_patcher" "$misettings_apk"
	remove_path_if_exists "$misettings_oat_dir"
	remove_part_metadata_prefix product priv-app/MISettings/oat
fi
if (( settings_ready == 1 )); then
	bash "$settings_patcher" "$settings_apk"
	remove_path_if_exists "$settings_oat_dir"
	remove_part_metadata_prefix system_ext priv-app/Settings/oat
fi

if (( feature_ready == 1 )); then
	_install_generated_file "$temporary_xml" "$feature_xml"
	std_print "✅ 已启用 dc_backlight_fps_incompatible：${feature_xml#"$project_dir"/}"
fi
if (( misettings_ready == 1 )); then
	std_print "✅ MISettings：保留完整刷新率列表，维持 144/165Hz 与 DC 的既有互斥阈值"
fi
if (( settings_ready == 1 )); then
	std_print "✅ Settings：移除 Pro 状态导致的高刷列表/写入回退，保留高刷切换时的 DC 互斥链路"
fi
std_print "处理完成"
