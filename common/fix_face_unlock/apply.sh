#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复人脸解锁功能与录入进度、完成收尾"
std_print "开放国内版人脸解锁区域、启用 TEE，并兼容标准 FaceManager 回调"
std_print

for part_name in mi_vendor product system_ext vendor; do
	check_part_exists "$part_name"
done

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
device_features="$project_dir/product/etc/device_features/nezha.xml"
# init_port_env 注入补丁仓库根目录。
# shellcheck disable=SC2154
settings_patcher="$port_dir/common/settings_apk_patcher.sh"
settings_apk="$project_dir/system_ext/priv-app/Settings/Settings.apk"
settings_oat_dir="$project_dir/system_ext/priv-app/Settings/oat"
permission_manifest="$patcher_dir/config/mi_vendor_sources.tsv"
source_permission="$project_dir/mi_vendor/etc/permissions/android.hardware.biometrics.face.xml"
target_permission="$project_dir/vendor/etc/permissions/android.hardware.biometrics.face.xml"
source_contexts="$(get_part_contexts_path mi_vendor)"
source_fsconfig="$(get_part_fsconfig_path mi_vendor)"
vendor_contexts="$(get_part_contexts_path vendor)"
vendor_fsconfig="$(get_part_fsconfig_path vendor)"

check_file_exists "$device_features"
for required_file in \
	"$settings_patcher" \
	"$settings_apk" \
	"$permission_manifest" \
	"$source_permission" \
	"$source_contexts" \
	"$source_fsconfig" \
	"$(get_part_contexts_path system_ext)" \
	"$(get_part_fsconfig_path system_ext)" \
	"$vendor_contexts" \
	"$vendor_fsconfig"; do
	check_file_exists "$required_file"
done
for regular_file in "$device_features" "$settings_apk" "$source_permission"; do
	if [[ -L "$regular_file" ]]; then
		err_print "不支持使用符号链接文件：$regular_file"
		exit 1
	fi
done
if ! command -v python3 >/dev/null 2>&1; then
	err_print "缺少 Python 3，无法安全修改人脸解锁特性配置"
	exit 1
fi
check_partition_metadata_tool >/dev/null

validate_source_file_manifest \
	"$project_dir/mi_vendor" \
	"$project_dir/vendor" \
	"$permission_manifest"
validate_translated_contexts \
	"$source_contexts" \
	"$permission_manifest" \
	/mi_vendor \
	/vendor
validate_translated_fsconfig \
	"$source_fsconfig" \
	"$permission_manifest" \
	mi_vendor \
	vendor

validate_metadata_updates() {
	local temporary_vendor_contexts=""
	local temporary_vendor_fsconfig=""
	local validation_status=0

	temporary_vendor_contexts="$(mktemp)" || return 1
	if (( validation_status == 0 )); then
		temporary_vendor_fsconfig="$(mktemp)" || validation_status=$?
	fi
	if (( validation_status == 0 )); then
		cp -p -- "$vendor_contexts" "$temporary_vendor_contexts" || validation_status=$?
		cp -p -- "$vendor_fsconfig" "$temporary_vendor_fsconfig" || validation_status=$?
	fi
	if (( validation_status == 0 )); then
		merge_translated_contexts \
			"$source_contexts" \
			"$temporary_vendor_contexts" \
			/mi_vendor \
			/vendor \
			"$permission_manifest" || validation_status=$?
	fi
	if (( validation_status == 0 )); then
		merge_translated_fsconfig \
			"$source_fsconfig" \
			"$temporary_vendor_fsconfig" \
			mi_vendor \
			vendor \
			"$permission_manifest" || validation_status=$?
	fi

	rm -f -- \
		"$temporary_vendor_contexts" \
		"$temporary_vendor_fsconfig"
	return "$validation_status"
}

if ! validate_metadata_updates; then
	err_print "人脸解锁目标 metadata 预检失败"
	exit 1
fi

if [[ -f "$target_permission" ]] && cmp -s -- "$source_permission" "$target_permission"; then
	face_permission_changed=false
else
	face_permission_changed=true
fi

temporary_device_features="$(mktemp "${device_features}.tmp.XXXXXX")"
cleanup() {
	rm -f -- "$temporary_device_features"
}
trap cleanup EXIT

face_unlock_status="$(python3 - "$device_features" "$temporary_device_features" <<'PY'
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


if len(sys.argv) != 3:
    raise SystemExit("人脸解锁特性补丁参数数量无效")

source_path = Path(sys.argv[1])
output_path = Path(sys.argv[2])
region_name = "support_face_unlock_region_dom"
tee_name = "support_tee_face_unlock"
whitespace = " \t\r\n"

try:
    original_text = source_path.read_text(encoding="utf-8")
    original_root = ET.fromstring(original_text)
except (OSError, UnicodeError, ET.ParseError) as error:
    raise SystemExit(f"解析人脸解锁特性配置失败：{source_path}：{error}")


def find_unique_node(root, tag, name):
    matches = [
        node
        for node in root.iter(tag)
        if node.get("name") == name
    ]
    if len(matches) != 1:
        raise SystemExit(
            f"特性 {name} 数量应为 1，实际为 {len(matches)}：{source_path}"
        )
    return matches[0]


def name_attribute(attributes):
    match = re.search(r"\bname\s*=\s*(['\"])(.*?)\1", attributes, re.DOTALL)
    return None if match is None else match.group(2)


def find_unique_text_element(text, tag, name, body_pattern):
    pattern = re.compile(
        rf"(?P<open><{re.escape(tag)}\b(?P<attrs>[^>]*)>)"
        rf"(?P<body>{body_pattern})"
        rf"(?P<close></{re.escape(tag)}>)",
        re.DOTALL,
    )
    matches = [
        match
        for match in pattern.finditer(text)
        if name_attribute(match.group("attrs")) == name
    ]
    if len(matches) != 1:
        raise SystemExit(f"无法唯一定位特性文本 {name}：{source_path}")
    return matches[0]


def replace_text_value(match, value):
    body = match.group("body")
    if body.strip(whitespace):
        leading = body[: len(body) - len(body.lstrip(whitespace))]
        trailing = body[len(body.rstrip(whitespace)) :]
    else:
        leading = ""
        trailing = ""
    return match.group("open") + leading + value + trailing + match.group("close")


region_node = find_unique_node(
    original_root, "string-array", region_name
)
region_items = list(region_node.findall("item"))
if not region_items:
    raise SystemExit(f"特性 {region_name} 不包含任何 item：{source_path}")
region_values = [(item.text or "").strip() for item in region_items]
region_changed = "ALL" not in region_values

tee_node = find_unique_node(original_root, "bool", tee_name)
tee_value = (tee_node.text or "").strip()
tee_changed = tee_value != "true"

updated_text = original_text
if region_changed:
    region_match = find_unique_text_element(
        updated_text, "string-array", region_name, ".*?"
    )
    item_pattern = re.compile(
        r"(?P<open><item\b[^>]*>)(?P<body>[^<]*)(?P<close></item>)",
        re.DOTALL,
    )
    region_body = region_match.group("body")
    text_items = list(item_pattern.finditer(region_body))
    if len(text_items) != len(region_items):
        raise SystemExit(
            f"无法完整定位特性 {region_name} 的全部 item：{source_path}"
        )
    updated_region_body = item_pattern.sub(
        lambda match: replace_text_value(match, "ALL"), region_body
    )
    updated_region = (
        region_match.group("open")
        + updated_region_body
        + region_match.group("close")
    )
    updated_text = (
        updated_text[: region_match.start()]
        + updated_region
        + updated_text[region_match.end() :]
    )

if tee_changed:
    tee_match = find_unique_text_element(updated_text, "bool", tee_name, "[^<]*")
    updated_tee = replace_text_value(tee_match, "true")
    updated_text = (
        updated_text[: tee_match.start()]
        + updated_tee
        + updated_text[tee_match.end() :]
    )

try:
    updated_root = ET.fromstring(updated_text)
except ET.ParseError as error:
    raise SystemExit(f"修改后的人脸解锁特性配置无效：{source_path}：{error}")

updated_region = find_unique_node(updated_root, "string-array", region_name)
updated_region_values = [
    (item.text or "").strip() for item in updated_region.findall("item")
]
if region_changed:
    if not updated_region_values or any(
        value != "ALL" for value in updated_region_values
    ):
        raise SystemExit(f"特性 {region_name} 的 item 未全部设置为 ALL")
elif "ALL" not in updated_region_values:
    raise SystemExit(f"特性 {region_name} 未保留 ALL")

updated_tee = find_unique_node(updated_root, "bool", tee_name)
if (updated_tee.text or "").strip() != "true":
    raise SystemExit(f"特性 {tee_name} 未设置为 true")

try:
    with output_path.open("w", encoding="utf-8", newline="") as output:
        output.write(updated_text)
except OSError as error:
    raise SystemExit(f"写入临时人脸解锁特性配置失败：{output_path}：{error}")

print(f"{str(region_changed).lower()}\t{str(tee_changed).lower()}")
PY
)"

IFS=$'\t' read -r region_changed tee_changed <<< "$face_unlock_status"
if [[ "$region_changed" != true && "$region_changed" != false ]]; then
	err_print "无效的人脸解锁区域修改状态：$region_changed"
	exit 1
fi
if [[ "$tee_changed" != true && "$tee_changed" != false ]]; then
	err_print "无效的 TEE 人脸解锁修改状态：$tee_changed"
	exit 1
fi

_install_generated_file "$temporary_device_features" "$device_features"

bash "$settings_patcher" face-enroll-finish "$settings_apk"
remove_path_if_exists "$settings_oat_dir"
remove_part_metadata_prefix system_ext priv-app/Settings/oat

python3 - "$device_features" <<'PY'
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


config_path = Path(sys.argv[1])
try:
    root = ET.parse(config_path).getroot()
except (OSError, ET.ParseError) as error:
    raise SystemExit(f"最终人脸解锁特性配置解析失败：{config_path}：{error}")


def unique_feature(tag, name):
    matches = [node for node in root.iter(tag) if node.get("name") == name]
    if len(matches) != 1:
        raise SystemExit(f"最终特性 {name} 数量应为 1，实际为 {len(matches)}")
    return matches[0]


region = unique_feature("string-array", "support_face_unlock_region_dom")
region_values = [(item.text or "").strip() for item in region.findall("item")]
if "ALL" not in region_values:
    raise SystemExit("最终人脸解锁区域配置不包含 ALL")

tee = unique_feature("bool", "support_tee_face_unlock")
if (tee.text or "").strip() != "true":
    raise SystemExit("最终 TEE 人脸解锁配置不为 true")
PY

apply_source_file_manifest \
	"$project_dir/mi_vendor" \
	"$project_dir/vendor" \
	"$permission_manifest"
merge_translated_contexts \
	"$source_contexts" \
	"$vendor_contexts" \
	/mi_vendor \
	/vendor \
	"$permission_manifest"
merge_translated_fsconfig \
	"$source_fsconfig" \
	"$vendor_fsconfig" \
	mi_vendor \
	vendor \
	"$permission_manifest"

if ! cmp -s -- "$source_permission" "$target_permission"; then
	err_print "人脸硬件特性声明迁移后校验失败：$target_permission"
	exit 1
fi
if ! grep -Fqx '/vendor/etc/permissions/android\.hardware\.biometrics\.face\.xml u:object_r:vendor_configs_file:s0' "$vendor_contexts"; then
	err_print "人脸硬件特性声明 contexts 写入失败"
	exit 1
fi
if ! grep -Fqx 'vendor/etc/permissions/android.hardware.biometrics.face.xml 0 0 0644' "$vendor_fsconfig"; then
	err_print "人脸硬件特性声明 fsconfig 写入失败"
	exit 1
fi

if [[ "$region_changed" == true ]]; then
	std_print "✅ support_face_unlock_region_dom 的所有 item 已设为 ALL"
else
	skip_print "support_face_unlock_region_dom 已包含 ALL"
fi
if [[ "$tee_changed" == true ]]; then
	std_print "✅ support_tee_face_unlock 已设为 true"
else
	skip_print "support_tee_face_unlock 已为 true"
fi
std_print "✅ Settings 已同步标准 FaceManager 的录入启动、实时进度与 remaining=0 完成回调"
if [[ "$face_permission_changed" == true ]]; then
	std_print "✅ 已将人脸硬件特性声明从 mi_vendor 迁移到最终 vendor"
else
	skip_print "vendor 人脸硬件特性声明已是当前原包版本"
fi
std_print "处理完成"
