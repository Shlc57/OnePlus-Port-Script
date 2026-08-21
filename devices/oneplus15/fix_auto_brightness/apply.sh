#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复一加 15 自动亮度"
std_print "校准启动默认亮度与物理边界：普通亮度 1400 nit，HBM 1800 nit"
std_print "保留亮度逻辑上限，仅校准环境光曲线并叠加 135 nit 启动默认值"
std_print

for part_name in vendor product; do
	check_part_exists "$part_name"
done

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
odm_build_props=(
	"$project_dir/odm/build.prop"
	"$project_dir/odm/etc/build.prop"
)
vendor_displayconfig="$project_dir/vendor/etc/displayconfig"
product_displayconfig="$project_dir/product/etc/displayconfig"
product_contexts="$(get_part_contexts_path product)"
contexts_patch="$patcher_dir/config/product_file_contexts"
vendor_fsconfig="$(get_part_fsconfig_path vendor)"
product_fsconfig="$(get_part_fsconfig_path product)"
product_fsconfig_patch="$patcher_dir/config/product_fsconfig"
panel_brightness_config="$patcher_dir/config/display_brightness_config_P_3.xml"
boot_brightness_overlay="$patcher_dir/prebuilt/product/overlay/OnePlus15BootBrightnessOverlay.apk"
boot_brightness_overlay_checksums="$patcher_dir/config/boot_brightness_overlay.sha256"
boot_brightness_overlay_target="$project_dir/product/overlay/OnePlus15BootBrightnessOverlay.apk"
auto_curve_overlay="$patcher_dir/prebuilt/product/overlay/MiuiFrameworkResOverlay.apk"
auto_curve_overlay_checksums="$patcher_dir/config/miui_framework_overlay.sha256"
auto_curve_overlay_target="$project_dir/product/overlay/MiuiFrameworkResOverlay.apk"
target_display_id="${PORT_TARGET_DISPLAY_ID:-}"
target_display_config="$product_displayconfig/display_id_${target_display_id}.xml"
aligned_auto_curve_overlay=""
auto_curve_overlay_install="$auto_curve_overlay"
temporary_display_config=""
target_contexts_patch=""
target_fsconfig_patch=""

cleanup() {
	if [[ -n "$aligned_auto_curve_overlay" ]]; then
		rm -f -- "$aligned_auto_curve_overlay"
	fi
	if [[ -n "$temporary_display_config" ]]; then
		rm -f -- "$temporary_display_config"
	fi
	if [[ -n "$target_contexts_patch" ]]; then
		rm -f -- "$target_contexts_patch"
	fi
	if [[ -n "$target_fsconfig_patch" ]]; then
		rm -f -- "$target_fsconfig_patch"
	fi
}
trap cleanup EXIT

if [[ ! "$target_display_id" =~ ^[1-9][0-9]{0,19}$ ]]; then
	err_print "PORT_TARGET_DISPLAY_ID 必须是 uint64 范围内的正十进制 Display ID：${target_display_id:-<未设置>}"
	exit 1
fi
# shellcheck disable=SC2071 # 固定长度十进制需按字典序比较，避免 Bash 有符号整数溢出。
if (( ${#target_display_id} == 20 )) && \
	[[ "$target_display_id" > "18446744073709551615" ]]; then
	err_print "PORT_TARGET_DISPLAY_ID 超出 uint64 范围：$target_display_id"
	exit 1
fi

target_contexts_patch="$(mktemp)"
target_fsconfig_patch="$(mktemp)"
printf '/product/etc/displayconfig/display_id_%s\\.xml u:object_r:system_file:s0\n' \
	"$target_display_id" > "$target_contexts_patch"
printf 'product/etc/displayconfig/display_id_%s.xml 0 0 0644\n' \
	"$target_display_id" > "$target_fsconfig_patch"
std_print "目标物理 Display ID：$target_display_id"

available_odm_build_props=()
for build_prop in "${odm_build_props[@]}"; do
	if [[ -L "$build_prop" ]]; then
		err_print "不支持直接修改符号链接：$build_prop"
		exit 1
	elif [[ ! -e "$build_prop" ]]; then
		warn_print "自动亮度属性目标不存在，跳过：${build_prop#"$project_dir"/}"
		continue
	elif [[ ! -f "$build_prop" ]]; then
		err_print "自动亮度属性目标不是普通文件：$build_prop"
		exit 1
	fi
	available_odm_build_props+=("$build_prop")
done
check_file_exists "$product_contexts"
check_file_exists "$contexts_patch"
check_file_exists "$vendor_fsconfig"
check_file_exists "$product_fsconfig"
check_file_exists "$product_fsconfig_patch"
check_file_exists "$panel_brightness_config"
check_file_exists "$boot_brightness_overlay"
check_file_exists "$boot_brightness_overlay_checksums"
check_file_exists "$auto_curve_overlay"
check_file_exists "$auto_curve_overlay_checksums"
if ! command -v python3 >/dev/null 2>&1; then
	err_print "缺少 Python 3，无法生成一加 15 高亮度映射"
	exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
	err_print "缺少 sha256sum，无法校验启动亮度 Overlay"
	exit 1
fi
zipalign_command=""
if [[ -n "${ZIPALIGN:-}" ]]; then
	if [[ ! -x "$ZIPALIGN" ]]; then
		err_print "ZIPALIGN 不可执行：$ZIPALIGN"
		exit 1
	fi
	zipalign_command="$ZIPALIGN"
elif command -v zipalign >/dev/null 2>&1; then
	zipalign_command="$(command -v zipalign)"
else
	for sdk_root in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "${ANDROID_SDK:-}"; do
		[[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]] || continue
		zipalign_candidate="$({
			find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 \
				-type f -name zipalign -perm -u+x -print
		} | LC_ALL=C sort -V | tail -n 1)"
		if [[ -n "$zipalign_candidate" ]]; then
			zipalign_command="$zipalign_candidate"
			break
		fi
	done
fi
if [[ -z "$zipalign_command" ]]; then
	err_print "缺少 zipalign；可通过 ZIPALIGN 指定可执行文件"
	exit 1
fi
if ! (cd -- "$patcher_dir" && sha256sum -c -- "$boot_brightness_overlay_checksums"); then
	err_print "启动亮度 Overlay 校验失败"
	exit 1
fi
if ! (cd -- "$patcher_dir" && sha256sum -c -- "$auto_curve_overlay_checksums"); then
	err_print "自动亮度曲线 Overlay 校验失败"
	exit 1
fi
if "$zipalign_command" -c 4 "$auto_curve_overlay" >/dev/null 2>&1; then
	std_print "✅ 自动亮度曲线 Overlay 已通过 4 字节对齐校验"
else
	aligned_auto_curve_overlay="$(mktemp)"
	if ! "$zipalign_command" -f 4 "$auto_curve_overlay" "$aligned_auto_curve_overlay"; then
		err_print "自动亮度曲线 Overlay 对齐失败"
		exit 1
	fi
	chmod --reference="$auto_curve_overlay" -- "$aligned_auto_curve_overlay"
	if ! "$zipalign_command" -c 4 "$aligned_auto_curve_overlay"; then
		err_print "自动亮度曲线 Overlay 对齐结果校验失败"
		exit 1
	fi
	auto_curve_overlay_install="$aligned_auto_curve_overlay"
	warn_print "预编译自动亮度曲线 Overlay 未对齐，已生成 4 字节对齐副本"
fi

if [[ ! -d "$vendor_displayconfig" || -L "$vendor_displayconfig" ]]; then
	err_print "vendor 显示配置目录不存在或不是普通目录：$vendor_displayconfig"
	exit 1
fi
if [[ -e "$product_displayconfig" || -L "$product_displayconfig" ]]; then
	if [[ ! -d "$product_displayconfig" || -L "$product_displayconfig" ]]; then
		err_print "product 显示配置路径不是普通目录：$product_displayconfig"
		exit 1
	fi
fi
if [[ -d "$target_display_config" ]]; then
	err_print "目标 Display ID 配置不能是目录：$target_display_config"
	exit 1
fi

validate_translated_fsconfig_prefix \
	"$vendor_fsconfig" \
	vendor/etc/displayconfig \
	product/etc/displayconfig

for overlay_name in AospFrameworkResOverlay.apk MiuiFrameworkResOverlay.apk; do
	overlay_path="$project_dir/product/overlay/$overlay_name"
	if [[ ! -f "$overlay_path" ]]; then
		err_print "自动亮度补丁要求保留 product/overlay/$overlay_name"
		err_print "删除原厂亮度 Overlay 会同时破坏自动亮度曲线，请恢复后再运行本补丁"
		exit 1
	fi
done

largest_display_config=""
largest_display_size=-1
while IFS= read -r candidate; do
	candidate_size="$(stat -c '%s' -- "$candidate")"
	if (( candidate_size > largest_display_size )); then
		largest_display_config="$candidate"
		largest_display_size="$candidate_size"
	fi
done < <(find "$vendor_displayconfig" -maxdepth 1 -type f -name 'display_id_*.xml' -print | LC_ALL=C sort)

if [[ -z "$largest_display_config" ]]; then
	err_print "vendor 显示配置目录中没有 display_id_*.xml"
	exit 1
fi

prop_key="ro.vendor.oplus.sensor.high_pwm_rgb"
for build_prop in "${available_odm_build_props[@]}"; do
	if grep -Eq "^[[:space:]]*${prop_key//./\\.}[[:space:]]*=" "$build_prop"; then
		comment_prop "$build_prop" "$prop_key"
		std_print "已禁用：${build_prop#"$project_dir/"} 中的 $prop_key"
	elif grep -Eq "^[[:space:]]*#[[:space:]]*${prop_key//./\\.}[[:space:]]*=" "$build_prop"; then
		skip_print "${build_prop#"$project_dir/"} 中的 $prop_key 已禁用"
	else
		warn_print "属性不存在，跳过：${build_prop#"$project_dir/"} 中的 $prop_key"
	fi
done

copy_tree_missing_only "$vendor_displayconfig" "$product_displayconfig"
std_print "✅ vendor 显示配置缺失项已补入 product"

replace_file_if_different "$largest_display_config" "$target_display_config"
std_print "✅ 已用 $(basename -- "$largest_display_config") 适配 Display ID $target_display_id"

temporary_display_config="$(mktemp "${target_display_config}.tmp.XXXXXX")"

brightness_summary="$(python3 - "$target_display_config" "$panel_brightness_config" "$temporary_display_config" <<'PY'
import math
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path


display_config_path = Path(sys.argv[1])
panel_config_path = Path(sys.argv[2])
output_path = Path(sys.argv[3])
default_nits = 135.0
standard_max_nits = 1400.0
hbm_max_nits = 1800.0
manual_logical_max_nits = 1060.0
manual_factor_second_values = (0.566, 0.802, 1.0)
manual_compensation_floor_logical_nits = 599.5
manual_compensation_width = 0.00001
manual_boundary_tolerance_nits = 0.2


def parse_finite(value, description):
    try:
        parsed = float(value)
    except (TypeError, ValueError):
        raise SystemExit(f"{description} 不是有效数字：{value!r}")
    if not math.isfinite(parsed):
        raise SystemExit(f"{description} 必须是有限数值：{value!r}")
    return parsed


try:
    panel_root = ET.parse(panel_config_path).getroot()
except (OSError, ET.ParseError) as error:
    raise SystemExit(f"解析 P3 面板亮度表失败：{panel_config_path}：{error}")

panel_table = panel_root.find("brightness_table")
if panel_root.tag != "root" or panel_table is None:
    raise SystemExit(f"P3 面板亮度表结构无效：{panel_config_path}")

panel_points = []
for index, level in enumerate(panel_table.findall("level")):
    fields = [field.strip() for field in (level.text or "").split(",")]
    if len(fields) != 4:
        raise SystemExit(f"P3 面板亮度表第 {index + 1} 行字段数不是 4")
    logical_level = parse_finite(fields[0], f"P3 第 {index + 1} 行 logical level")
    backlight = parse_finite(fields[1], f"P3 第 {index + 1} 行 backlight")
    nits = parse_finite(fields[2], f"P3 第 {index + 1} 行 nits")
    parse_finite(fields[3], f"P3 第 {index + 1} 行 factor")
    if logical_level < 0.0 or backlight < 0.0 or nits < 0.0:
        raise SystemExit(f"P3 面板亮度表第 {index + 1} 行不能包含负数")
    if panel_points:
        previous_level, previous_backlight, previous_nits = panel_points[-1]
        if logical_level <= previous_level:
            raise SystemExit(
                f"P3 logical level 必须严格递增：{previous_level} -> {logical_level}"
            )
        if backlight <= previous_backlight:
            raise SystemExit(
                f"P3 backlight 必须严格递增：{previous_backlight} -> {backlight}"
            )
        if nits < previous_nits:
            raise SystemExit(f"P3 nits 必须单调不减：{previous_nits} -> {nits}")
    panel_points.append((logical_level, backlight, nits))

if len(panel_points) < 2 or panel_points[0] != (0.0, 0.0, 0.0):
    raise SystemExit(f"P3 面板亮度表必须包含从 0,0,0 开始的完整映射：{panel_config_path}")

max_panel_backlight = panel_points[-1][1]
max_panel_nits = panel_points[-1][2]
if not math.isclose(max_panel_nits, hbm_max_nits, abs_tol=1e-6):
    raise SystemExit(
        f"P3 面板末端不是 {hbm_max_nits:g} nit：{max_panel_nits:g}"
    )


def panel_nits_from_brightness(brightness):
    target_backlight = brightness * max_panel_backlight
    if target_backlight <= panel_points[0][1]:
        return panel_points[0][2]
    for left, right in zip(panel_points, panel_points[1:]):
        if target_backlight <= right[1]:
            ratio = (target_backlight - left[1]) / (right[1] - left[1])
            return left[2] + ratio * (right[2] - left[2])
    raise SystemExit(f"目标 brightness 超出 P3 范围：{brightness:g}")


deduplicated_panel_points = []
for point in panel_points:
    if deduplicated_panel_points and point[2] == deduplicated_panel_points[-1][2]:
        deduplicated_panel_points[-1] = point
    else:
        deduplicated_panel_points.append(point)


def brightness_from_panel_nits(target_nits):
    if target_nits <= deduplicated_panel_points[0][2]:
        return deduplicated_panel_points[0][1] / max_panel_backlight
    for left, right in zip(
        deduplicated_panel_points, deduplicated_panel_points[1:]
    ):
        if target_nits <= right[2]:
            ratio = (target_nits - left[2]) / (right[2] - left[2])
            backlight = left[1] + ratio * (right[1] - left[1])
            return backlight / max_panel_backlight
    raise SystemExit(f"目标 nit 超出 P3 范围：{target_nits:g}")


default_brightness = brightness_from_panel_nits(default_nits)
new_transition = brightness_from_panel_nits(standard_max_nits)
manual_compensation_start = new_transition - manual_compensation_width
if not 0.0 < default_brightness < manual_compensation_start < new_transition < 1.0:
    raise SystemExit(
        "P3 默认值、手动补偿段或 HBM 分界无效："
        f"default={default_brightness:g}, compensationStart={manual_compensation_start:g}, "
        f"transition={new_transition:g}"
    )

manual_compensation_start_physical_nits = panel_nits_from_brightness(
    manual_compensation_start
)
standard_label_scale = (
    manual_compensation_floor_logical_nits
    / manual_compensation_start_physical_nits
)
manual_logical_limits = sorted(
    {
        600.0,
        *(manual_logical_max_nits * factor for factor in manual_factor_second_values),
    }
)
if manual_compensation_floor_logical_nits >= manual_logical_limits[0]:
    raise SystemExit(
        "手动补偿段起点必须低于控制器最小逻辑上限："
        f"{manual_compensation_floor_logical_nits:g} >= {manual_logical_limits[0]:g}"
    )

try:
    original_text = display_config_path.read_text(encoding="utf-8")
    display_root = ET.fromstring(original_text)
except (OSError, UnicodeError, ET.ParseError) as error:
    raise SystemExit(f"解析 Display ID 配置失败：{display_config_path}：{error}")

if display_root.tag != "displayConfiguration":
    raise SystemExit(f"Display ID 配置根节点必须是 displayConfiguration：{display_config_path}")
screen_brightness_defaults = display_root.findall("screenBrightnessDefault")
if len(screen_brightness_defaults) > 1:
    raise SystemExit(f"Display ID 包含多个 screenBrightnessDefault：{display_config_path}")
if display_root.find("autoBrightness") is not None:
    raise SystemExit(f"原版 Display ID 不应包含 autoBrightness：{display_config_path}")

screen_map = display_root.find("screenBrightnessMap")
high_brightness_mode = display_root.find("highBrightnessMode")
if screen_map is None or high_brightness_mode is None:
    raise SystemExit(f"Display ID 配置缺少亮度映射或 HBM：{display_config_path}")
if high_brightness_mode.get("enabled") != "true":
    raise SystemExit(f"Display ID 配置未启用 HBM：{display_config_path}")

base_points = []
for index, point in enumerate(screen_map.findall("point")):
    value = parse_finite(point.findtext("value"), f"原版第 {index + 1} 点 value")
    nits = parse_finite(point.findtext("nits"), f"原版第 {index + 1} 点 nits")
    if base_points and (
        value <= base_points[-1][0] or nits < base_points[-1][1]
    ):
        raise SystemExit("原版 screenBrightnessMap 的 value 必须严格递增，nits 必须单调不减")
    base_points.append((value, nits))

if (
    len(base_points) < 2
    or not math.isclose(base_points[0][0], 0.0, abs_tol=1e-9)
    or not math.isclose(base_points[-1][0], 1.0, abs_tol=1e-9)
):
    raise SystemExit("原版 screenBrightnessMap 范围无效")

original_transition = parse_finite(
    high_brightness_mode.findtext("transitionPoint"),
    "原版 HBM transitionPoint",
)
if not 0.0 < original_transition < 1.0:
    raise SystemExit(f"原版 HBM transitionPoint 无效：{original_transition:g}")

# 这里的 nits 作为小米亮度控制器的逻辑坐标。把其可能出现的
# 599.96~1060 逻辑上限压入 P3 1400 nit 前的极窄区间，物理请求边界保持不变。
generated_candidates = []
for value, _ in base_points:
    if value < manual_compensation_start:
        generated_candidates.append(
            (value, panel_nits_from_brightness(value) * standard_label_scale)
        )

generated_candidates.extend(
    (
        (
            default_brightness,
            panel_nits_from_brightness(default_brightness) * standard_label_scale,
        ),
        (manual_compensation_start, manual_compensation_floor_logical_nits),
        (new_transition, manual_logical_max_nits),
    )
)

hbm_label_scale = (hbm_max_nits - manual_logical_max_nits) / (
    hbm_max_nits - standard_max_nits
)
for value, _ in base_points:
    if new_transition < value < 1.0:
        physical_nits = panel_nits_from_brightness(value)
        generated_candidates.append(
            (
                value,
                manual_logical_max_nits
                + (physical_nits - standard_max_nits) * hbm_label_scale,
            )
        )
generated_candidates.append((1.0, hbm_max_nits))

generated_candidates.sort(key=lambda point: point[0])
generated_points = []
for point in generated_candidates:
    if generated_points and math.isclose(
        point[0], generated_points[-1][0], abs_tol=5e-10
    ):
        if not math.isclose(point[1], generated_points[-1][1], abs_tol=1e-6):
            raise SystemExit(
                "同一 brightness 生成了不同逻辑 nit："
                f"{generated_points[-1]} 与 {point}"
            )
        generated_points[-1] = point
    else:
        generated_points.append(point)

for index in range(1, len(generated_points)):
    previous = generated_points[index - 1]
    current = generated_points[index]
    if current[0] <= previous[0] or current[1] <= previous[1]:
        raise SystemExit(
            "生成的 screenBrightnessMap 不是严格递增曲线："
            f"{previous} -> {current}"
        )
if not math.isclose(generated_points[-1][0], 1.0, abs_tol=1e-9):
    raise SystemExit("生成的 screenBrightnessMap 未到达 brightness 1.0")
if not math.isclose(generated_points[-1][1], hbm_max_nits, abs_tol=1e-6):
    raise SystemExit("生成的 screenBrightnessMap 未到达 1800 nit")

newline = "\r\n" if "\r\n" in original_text else "\n"
screen_map_pattern = re.compile(
    r"(?ms)^  <screenBrightnessMap\b[^>]*>.*?^  </screenBrightnessMap>"
)
if len(screen_map_pattern.findall(original_text)) != 1:
    raise SystemExit(f"无法唯一定位 screenBrightnessMap：{display_config_path}")

screen_map_lines = ['  <screenBrightnessMap interpolation="linear">']
critical_values = (
    default_brightness,
    manual_compensation_start,
    new_transition,
)
for value, nits in generated_points:
    value_text = (
        f"{value:.9f}"
        if any(math.isclose(value, critical, abs_tol=5e-10) for critical in critical_values)
        else f"{value:.4f}"
    )
    screen_map_lines.extend(
        (
            "    <point>",
            f"      <value>{value_text}</value>",
            f"      <nits>{nits:.4f}</nits>",
            "    </point>",
        )
    )
screen_map_lines.append("  </screenBrightnessMap>")
screen_map_block = newline.join(screen_map_lines)

updated_text, map_count = screen_map_pattern.subn(
    lambda _: screen_map_block,
    original_text,
    count=1,
)
if map_count != 1:
    raise SystemExit("替换 screenBrightnessMap 失败")

default_block = (
    f"  <screenBrightnessDefault>{default_brightness:.9f}</screenBrightnessDefault>"
)
default_pattern = re.compile(
    r"(?ms)^  <screenBrightnessDefault\b[^>]*>[^<]+</screenBrightnessDefault>"
)
if screen_brightness_defaults:
    if len(default_pattern.findall(updated_text)) != 1:
        raise SystemExit(f"无法唯一定位 screenBrightnessDefault：{display_config_path}")
    updated_text, default_count = default_pattern.subn(
        lambda _: default_block,
        updated_text,
        count=1,
    )
    if default_count != 1:
        raise SystemExit("更新 screenBrightnessDefault 失败")
else:
    generated_map_match = screen_map_pattern.search(updated_text)
    if generated_map_match is None:
        raise SystemExit("插入 screenBrightnessDefault 时未找到 screenBrightnessMap")
    updated_text = (
        updated_text[: generated_map_match.start()]
        + default_block
        + newline
        + newline
        + updated_text[generated_map_match.start() :]
    )

transition_pattern = re.compile(
    r"(?s)(<highBrightnessMode\b[^>]*>.*?<transitionPoint>)[^<]+(</transitionPoint>)"
)
updated_text, transition_count = transition_pattern.subn(
    lambda match: f"{match.group(1)}{new_transition:.9f}{match.group(2)}",
    updated_text,
    count=1,
)
if transition_count != 1:
    raise SystemExit(f"无法唯一更新 HBM transitionPoint：{display_config_path}")

try:
    generated_root = ET.fromstring(updated_text)
except ET.ParseError as error:
    raise SystemExit(f"生成的 Display ID 配置 XML 无效：{error}")

if generated_root.find("autoBrightness") is not None:
    raise SystemExit("生成的 Display ID 不应注入 autoBrightness")
generated_default = parse_finite(
    generated_root.findtext("screenBrightnessDefault"),
    "生成的 screenBrightnessDefault",
)
if not math.isclose(generated_default, default_brightness, abs_tol=5e-10):
    raise SystemExit("生成的 screenBrightnessDefault 与 P3 135 nit 请求值不一致")
generated_transition = parse_finite(
    generated_root.findtext("./highBrightnessMode/transitionPoint"),
    "生成的 HBM transitionPoint",
)
if not math.isclose(generated_transition, new_transition, abs_tol=5e-10):
    raise SystemExit("生成的 HBM transitionPoint 与 1400 nit 分界不一致")

generated_screen_map = generated_root.find("screenBrightnessMap")
if generated_screen_map is None:
    raise SystemExit("生成的 Display ID 缺少 screenBrightnessMap")
generated_xml_points = []
for index, point in enumerate(generated_screen_map.findall("point")):
    value = parse_finite(point.findtext("value"), f"生成的第 {index + 1} 点 value")
    nits = parse_finite(point.findtext("nits"), f"生成的第 {index + 1} 点 nits")
    if generated_xml_points and (
        value <= generated_xml_points[-1][0] or nits <= generated_xml_points[-1][1]
    ):
        raise SystemExit(
            "格式化后的 screenBrightnessMap 不是严格递增曲线："
            f"{generated_xml_points[-1]} -> {(value, nits)}"
        )
    generated_xml_points.append((value, nits))


def brightness_from_generated_nits(target_nits):
    if target_nits <= generated_xml_points[0][1]:
        return generated_xml_points[0][0]
    for left, right in zip(generated_xml_points, generated_xml_points[1:]):
        if target_nits <= right[1]:
            ratio = (target_nits - left[1]) / (right[1] - left[1])
            return left[0] + ratio * (right[0] - left[0])
    raise SystemExit(f"目标逻辑 nit 超出生成映射：{target_nits:g}")


if not math.isclose(
    panel_nits_from_brightness(generated_default), default_nits, abs_tol=1e-3
):
    raise SystemExit("生成的默认 brightness 未落在 P3 135 nit")
if not math.isclose(
    panel_nits_from_brightness(generated_transition),
    standard_max_nits,
    abs_tol=1e-3,
):
    raise SystemExit("生成的 HBM 分界未落在 P3 1400 nit")
if not math.isclose(
    panel_nits_from_brightness(generated_xml_points[-1][0]),
    hbm_max_nits,
    abs_tol=1e-3,
):
    raise SystemExit("生成的 HBM 末端未落在 P3 1800 nit")

manual_physical_limits = []
for logical_limit in manual_logical_limits:
    request = brightness_from_generated_nits(logical_limit)
    physical_nits = panel_nits_from_brightness(request)
    if not math.isclose(
        physical_nits,
        standard_max_nits,
        abs_tol=manual_boundary_tolerance_nits,
    ):
        raise SystemExit(
            f"手动逻辑上限 {logical_limit:g} 仅映射到 {physical_nits:g} nit，"
            f"未落在 {standard_max_nits:g} nit 边界"
        )
    manual_physical_limits.append(physical_nits)

try:
    output_path.write_text(updated_text, encoding="utf-8", newline="")
except OSError as error:
    raise SystemExit(f"写入临时 Display ID 配置失败：{output_path}：{error}")

print(
    f"默认 {default_brightness:.9f}（{default_nits:g} nit）；"
    f"手动逻辑上限 {manual_logical_limits[0]:.2f}~{manual_logical_limits[-1]:.2f} "
    f"映射到 {min(manual_physical_limits):.3f}~{max(manual_physical_limits):.3f} nit；"
    f"普通/HBM 分界 {new_transition:.9f}（{standard_max_nits:g} nit，"
    f"backlight {new_transition * max_panel_backlight:.3f}/{max_panel_backlight:g}）；"
    f"HBM 末端 1.000000000（{hbm_max_nits:g} nit）；"
    f"总计 {len(generated_points)} 点"
)
PY
)"

_install_generated_file "$temporary_display_config" "$target_display_config"
std_print "✅ 已生成 135/1400/1800 nit 边界校准映射：$brightness_summary"

replace_file_if_different "$auto_curve_overlay_install" "$auto_curve_overlay_target"
std_print "✅ 已校准环境光默认曲线（0→2、30→40、600→70、5000→1060 逻辑 nit），保留 1060 逻辑上限"

replace_file_if_different "$boot_brightness_overlay" "$boot_brightness_overlay_target"
std_print "✅ 已加入仅覆盖启动默认亮度的 135 nit 单资源 Overlay"

merge_translated_fsconfig_prefix \
	"$vendor_fsconfig" \
	"$product_fsconfig" \
	vendor/etc/displayconfig \
	product/etc/displayconfig
merge_fsconfig_file "$product_fsconfig_patch" "$product_fsconfig"
merge_contexts_file "$contexts_patch" "$product_contexts"
merge_contexts_file "$target_contexts_patch" "$product_contexts"
merge_fsconfig_file "$target_fsconfig_patch" "$product_fsconfig"
std_print "✅ product fsconfig 与 SELinux 文件上下文合并完成"
std_print "处理完成"
