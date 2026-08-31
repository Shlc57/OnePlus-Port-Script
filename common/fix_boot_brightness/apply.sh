#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "安装机型启动默认亮度 Overlay（common 模块，按机型 Profile 分发）"
std_print

check_part_exists product

# ---- 机型 Profile 识别 -------------------------------------------------------
# 显式指定优先（BOOT_BRIGHTNESS_PROFILE=oneplus15|ace6|ace6t）；否则按 init_port_env
# 识别的底包设备代号、市场名或显示 Target 自动匹配 profiles/*/profile.props。
declare -a profile_dirs=()
for candidate_profile in "$patcher_dir"/profiles/*/; do
	if [[ -f "$candidate_profile/profile.props" ]]; then
		profile_dirs+=("$candidate_profile")
	fi
done
if (( ${#profile_dirs[@]} == 0 )); then
	err_print "common/fix_boot_brightness 缺少 profiles/*/profile.props"
	exit 1
fi

profile_prop() {
	local props_file="$1" key="$2"
	awk -F'=' -v key="$key" '
		$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
			value = substr($0, index($0, "=") + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			print value
			exit
		}' "$props_file"
}

profile_list_contains() {
	local list="$1" current="$2" item
	[[ -z "$current" || -z "$list" ]] && return 1
	# shellcheck disable=SC2020 # 逗号/分号需逐字符替换为换行，重复换行符是刻意为之。
	while IFS= read -r item; do
		[[ -n "$item" && "$item" == "$current" ]] && return 0
	done < <(tr ',;' '\n\n' <<< "$list")
	return 1
}

profile_dir=""
if [[ -n "${BOOT_BRIGHTNESS_PROFILE:-}" ]]; then
	profile_dir="$patcher_dir/profiles/${BOOT_BRIGHTNESS_PROFILE}"
	if [[ ! -f "$profile_dir/profile.props" ]]; then
		err_print "未找到机型 Profile：${BOOT_BRIGHTNESS_PROFILE}；可用：${profile_dirs[*]#"$patcher_dir"/profiles/}"
		exit 1
	fi
else
	for candidate_profile in "${profile_dirs[@]}"; do
		candidate_props="$candidate_profile/profile.props"
		if profile_list_contains "$(profile_prop "$candidate_props" device_codes)" "${PORT_BASE_DEVICE_CODE:-}" \
			|| profile_list_contains "$(profile_prop "$candidate_props" market_names)" "${PORT_BASE_DEVICE_MARKET_NAME:-}" \
			|| profile_list_contains "$(profile_prop "$candidate_props" display_targets)" "${PORT_DISPLAY_TARGET:-}"; then
			profile_dir="$candidate_profile"
			break
		fi
	done
	if [[ -z "$profile_dir" ]]; then
		err_print "未检测到匹配的机型 Profile：PORT_BASE_DEVICE_CODE=${PORT_BASE_DEVICE_CODE:-<空>}，PORT_BASE_DEVICE_MARKET_NAME=${PORT_BASE_DEVICE_MARKET_NAME:-<空>}，PORT_DISPLAY_TARGET=${PORT_DISPLAY_TARGET:-<空>}"
		err_print "可用 Profile：${profile_dirs[*]#"$patcher_dir"/profiles/}；也可用 BOOT_BRIGHTNESS_PROFILE 显式指定"
		exit 1
	fi
fi
profile_name="${profile_dir#"$patcher_dir"/profiles/}"
profile_display_name="$(profile_prop "$profile_dir/profile.props" display_name)"
profile_boot_overlay_name="$(profile_prop "$profile_dir/profile.props" boot_overlay_name)"
profile_remove_legacy_overlay="$(profile_prop "$profile_dir/profile.props" remove_legacy_overlay)"
std_print "匹配机型 Profile：$profile_name（$profile_display_name）"

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
product_contexts="$(get_part_contexts_path product)"
product_fsconfig="$(get_part_fsconfig_path product)"
# shellcheck disable=SC2154 # project_dir 由 init_port_env 注入。
overlay_target="$project_dir/product/overlay/$profile_boot_overlay_name"
# 随启动亮度一并移除的旧自动亮度曲线 Overlay；各机型 Profile 均声明移除
# MiuiFrameworkResOverlay.apk，自动亮度曲线改由 common/coloros_display 生成。
legacy_auto_overlay_name="$profile_remove_legacy_overlay"

validate_overlay_name() {
	local name="$1" label="$2"
	if [[ ! "$name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.apk$ ]] || [[ "$name" == *..* ]]; then
		err_print "$label 名无效：$name"
		exit 1
	fi
}

# ---- 校验阶段：全部前提通过后才允许修改工作树 --------------------------------
validate_overlay_name "$profile_boot_overlay_name" "启动亮度 Overlay 目标"
if [[ -n "$legacy_auto_overlay_name" ]]; then
	validate_overlay_name "$legacy_auto_overlay_name" "旧自动亮度 Overlay 目标"
fi

for required_file in \
	"$product_contexts" \
	"$product_fsconfig" \
	"$profile_dir/config/boot_brightness_overlay.sha256"; do
	check_file_exists "$required_file"
done
for metadata_file in "$product_contexts" "$product_fsconfig"; do
	if [[ -L "$metadata_file" ]]; then
		err_print "启动亮度 metadata 不能是符号链接：$metadata_file"
		exit 1
	fi
done
if [[ -e "$overlay_target" && (! -f "$overlay_target" || -L "$overlay_target") ]]; then
	err_print "启动亮度 Overlay 目标必须是普通文件：$overlay_target"
	exit 1
fi
overlay_source="$profile_dir/prebuilt/product/overlay/$profile_boot_overlay_name"
if [[ -L "$overlay_source" || ! -f "$overlay_source" ]]; then
	err_print "启动亮度 Overlay 来源不存在或不是普通文件：$overlay_source"
	exit 1
fi
if ! command -v sha256sum >/dev/null 2>&1; then
	err_print "缺少 sha256sum，无法校验启动亮度 Overlay"
	exit 1
fi

# 校验文件保持"哈希  路径"格式；只比对首列哈希。
expected_hash="$(awk 'NR==1{print tolower($1); exit}' "$profile_dir/config/boot_brightness_overlay.sha256")"
if [[ ! "$expected_hash" =~ ^[0-9a-f]{64}$ ]]; then
	err_print "启动亮度 Overlay 校验文件缺少有效 SHA-256：$profile_dir/config/boot_brightness_overlay.sha256"
	exit 1
fi
actual_hash="$(sha256sum -- "$overlay_source")"
actual_hash="${actual_hash%% *}"
if [[ "$actual_hash" != "$expected_hash" ]]; then
	err_print "启动亮度 Overlay 校验失败：$overlay_source"
	exit 1
fi

boot_contexts_patch="$(mktemp)"
boot_fsconfig_patch="$(mktemp)"
cleanup() {
	rm -f -- "$boot_contexts_patch" "$boot_fsconfig_patch"
}
trap cleanup EXIT
boot_contexts_regex="${profile_boot_overlay_name//./\\.}"
printf '/product/overlay/%s u:object_r:system_file:s0\n' "$boot_contexts_regex" > "$boot_contexts_patch"
printf 'product/overlay/%s 0 0 0644\n' "$profile_boot_overlay_name" > "$boot_fsconfig_patch"

# ---- 执行阶段 ------------------------------------------------------------------
# 1. 安装启动亮度 Overlay 并同步 metadata。
replace_file_if_different "$overlay_source" "$overlay_target"
merge_contexts_file "$boot_contexts_patch" "$product_contexts"
merge_fsconfig_file "$boot_fsconfig_patch" "$product_fsconfig"
std_print "✅ 已保留 product/overlay/$profile_boot_overlay_name"
std_print "✅ 启动亮度 Overlay contexts/fsconfig 已同步"

# 2. 按 Profile 移除旧自动亮度曲线 Overlay。
if [[ -n "$legacy_auto_overlay_name" ]]; then
	legacy_auto_overlay_target="$project_dir/product/overlay/$legacy_auto_overlay_name"
	remove_part_metadata_prefix product "overlay/$legacy_auto_overlay_name"
	remove_path_if_exists "$legacy_auto_overlay_target"
	std_print "✅ 已移除旧自动亮度曲线 Overlay（$legacy_auto_overlay_name）"
fi
std_print "处理完成"
