#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "禁用目标设备不支持的 CameraMR 特殊输入功能"
std_print "避免将 Oplus 活动识别传感器误作小米 CameraMR 传感器，并阻断开机窗口焦点初始化崩溃"
std_print

check_part_exists product

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
device_features="$project_dir/product/etc/cust_features/device_features.xml"
settings_features="$project_dir/product/etc/cust_features/cust_features.xml"

camera_mr_patch_ready=1
for feature_file in "$device_features" "$settings_features"; do
	if [[ -L "$feature_file" ]]; then
		err_print "不支持直接修改符号链接：$feature_file"
		exit 1
	elif [[ ! -e "$feature_file" ]]; then
		warn_print "待修改的 CameraMR 特性文件不存在，跳过：${feature_file#"$project_dir"/}"
		camera_mr_patch_ready=0
	elif [[ ! -f "$feature_file" ]]; then
		err_print "待修改的 CameraMR 特性路径不是普通文件：$feature_file"
		exit 1
	fi
done
if (( camera_mr_patch_ready == 0 )); then
	warn_print "CameraMR 两项特性需要同步修改，已跳过本补丁"
	std_print "处理完成"
	exit 0
fi

if ! command -v python3 >/dev/null 2>&1; then
	err_print "缺少 Python 3，无法安全修改 CameraMR 特性配置"
	exit 1
fi

temporary_device_features="$(mktemp "${device_features}.tmp.XXXXXX")"
temporary_settings_features="$(mktemp "${settings_features}.tmp.XXXXXX")"
cleanup() {
	rm -f -- "$temporary_device_features" "$temporary_settings_features"
}
trap cleanup EXIT

camera_mr_summary="$(python3 - \
	"$device_features" "$temporary_device_features" input_support_camera_mr \
	"$settings_features" "$temporary_settings_features" settings_is_support_camera_mr_function <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


if len(sys.argv) != 7:
    raise SystemExit("CameraMR 特性补丁参数数量无效")

targets = (
    (Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]),
    (Path(sys.argv[4]), Path(sys.argv[5]), sys.argv[6]),
)

for source_path, output_path, feature_name in targets:
    try:
        original_text = source_path.read_text(encoding="utf-8")
        original_root = ET.fromstring(original_text)
    except (OSError, UnicodeError, ET.ParseError) as error:
        raise SystemExit(f"解析特性配置失败：{source_path}：{error}")

    feature_nodes = [
        node
        for node in original_root.iter("bool")
        if node.get("name") == feature_name
    ]
    if len(feature_nodes) != 1:
        raise SystemExit(
            f"特性 {feature_name} 数量应为 1，实际为 {len(feature_nodes)}："
            f"{source_path}"
        )

    original_value = (feature_nodes[0].text or "").strip().lower()
    if original_value not in {"true", "false"}:
        raise SystemExit(
            f"特性 {feature_name} 不是有效布尔值：{original_value!r}："
            f"{source_path}"
        )

    feature_pattern = re.compile(
        r"(?P<open><bool[ \t]+name=(?P<quote>['\"])"
        + re.escape(feature_name)
        + r"(?P=quote)[ \t]*>)(?P<leading>[ \t\r\n]*)"
        r"(?:true|false)(?P<trailing>[ \t\r\n]*)(?P<close></bool>)"
    )
    text_matches = list(feature_pattern.finditer(original_text))
    if len(text_matches) != 1:
        raise SystemExit(
            f"无法唯一定位特性文本 {feature_name}：{source_path}"
        )

    match = text_matches[0]
    replacement = (
        match.group("open")
        + match.group("leading")
        + "false"
        + match.group("trailing")
        + match.group("close")
    )
    updated_text = (
        original_text[: match.start()]
        + replacement
        + original_text[match.end() :]
    )

    try:
        updated_root = ET.fromstring(updated_text)
    except ET.ParseError as error:
        raise SystemExit(f"修改后的特性配置无效：{source_path}：{error}")

    updated_nodes = [
        node
        for node in updated_root.iter("bool")
        if node.get("name") == feature_name
    ]
    if len(updated_nodes) != 1 or (updated_nodes[0].text or "").strip() != "false":
        raise SystemExit(f"特性 {feature_name} 未被唯一设置为 false：{source_path}")

    try:
        with output_path.open("w", encoding="utf-8", newline="") as output:
            output.write(updated_text)
    except OSError as error:
        raise SystemExit(f"写入临时特性配置失败：{output_path}：{error}")

print("input_support_camera_mr=false；settings_is_support_camera_mr_function=false")
PY
)"

if cmp -s -- "$temporary_device_features" "$device_features"; then
	device_features_changed=false
else
	device_features_changed=true
fi
if cmp -s -- "$temporary_settings_features" "$settings_features"; then
	settings_features_changed=false
else
	settings_features_changed=true
fi

_install_generated_file "$temporary_device_features" "$device_features"
_install_generated_file "$temporary_settings_features" "$settings_features"

python3 - \
	"$device_features" input_support_camera_mr \
	"$settings_features" settings_is_support_camera_mr_function <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


if len(sys.argv) != 5:
    raise SystemExit("CameraMR 最终校验参数数量无效")

targets = (
    (Path(sys.argv[1]), sys.argv[2]),
    (Path(sys.argv[3]), sys.argv[4]),
)

for config_path, feature_name in targets:
    try:
        root = ET.parse(config_path).getroot()
    except (OSError, ET.ParseError) as error:
        raise SystemExit(f"最终特性配置解析失败：{config_path}：{error}")

    matches = [
        node
        for node in root.iter("bool")
        if node.get("name") == feature_name
    ]
    if len(matches) != 1 or (matches[0].text or "").strip() != "false":
        raise SystemExit(f"最终 CameraMR 特性校验失败：{feature_name}")
PY

if [[ "$device_features_changed" == true ]]; then
	std_print "✅ 已更新：product/etc/cust_features/device_features.xml"
else
	skip_print "input_support_camera_mr 已为 false"
fi
if [[ "$settings_features_changed" == true ]]; then
	std_print "✅ 已更新：product/etc/cust_features/cust_features.xml"
else
	skip_print "settings_is_support_camera_mr_function 已为 false"
fi
std_print "✅ $camera_mr_summary"
std_print "处理完成"
