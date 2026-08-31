#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

# ---- 机型 Profile 识别 -------------------------------------------------------
# 显式指定优先（COLOROS_DISPLAY_PROFILE=oneplus15|ace6|ace6t）；否则按 init_port_env
# 识别的底包设备代号、市场名或显示 Target 自动匹配 profiles/*/profile.props。
declare -a coloros_profile_dirs=()
for candidate_profile in "$patcher_dir"/profiles/*/; do
	if [[ -f "$candidate_profile/profile.props" ]]; then
		coloros_profile_dirs+=("$candidate_profile")
	fi
done
if (( ${#coloros_profile_dirs[@]} == 0 )); then
	err_print "common/coloros_display 缺少 profiles/*/profile.props"
	exit 1
fi

coloros_profile_prop() {
	local props_file="$1" key="$2"
	awk -F'=' -v key="$key" '
		$0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
			value = substr($0, index($0, "=") + 1)
			gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
			print value
			exit
		}' "$props_file"
}

coloros_profile_list_contains() {
	local list="$1" current="$2" item
	[[ -z "$current" || -z "$list" ]] && return 1
	# shellcheck disable=SC2020 # 逗号/分号需逐字符替换为换行，重复换行符是刻意为之。
	while IFS= read -r item; do
		[[ -n "$item" && "$item" == "$current" ]] && return 0
	done < <(tr ',;' '\n\n' <<< "$list")
	return 1
}

profile_dir=""
if [[ -n "${COLOROS_DISPLAY_PROFILE:-}" ]]; then
	profile_dir="$patcher_dir/profiles/${COLOROS_DISPLAY_PROFILE}"
	if [[ ! -f "$profile_dir/profile.props" ]]; then
		err_print "未找到机型 Profile：${COLOROS_DISPLAY_PROFILE}；可用：${coloros_profile_dirs[*]#"$patcher_dir"/profiles/}"
		exit 1
	fi
else
	for candidate_profile in "${coloros_profile_dirs[@]}"; do
		candidate_props="$candidate_profile/profile.props"
		if coloros_profile_list_contains "$(coloros_profile_prop "$candidate_props" device_codes)" "${PORT_BASE_DEVICE_CODE:-}" \
			|| coloros_profile_list_contains "$(coloros_profile_prop "$candidate_props" market_names)" "${PORT_BASE_DEVICE_MARKET_NAME:-}" \
			|| coloros_profile_list_contains "$(coloros_profile_prop "$candidate_props" display_targets)" "${PORT_DISPLAY_TARGET:-}"; then
			profile_dir="$candidate_profile"
			break
		fi
	done
	if [[ -z "$profile_dir" ]]; then
		err_print "未检测到匹配的机型 Profile：PORT_BASE_DEVICE_CODE=${PORT_BASE_DEVICE_CODE:-<空>}，PORT_BASE_DEVICE_MARKET_NAME=${PORT_BASE_DEVICE_MARKET_NAME:-<空>}，PORT_DISPLAY_TARGET=${PORT_DISPLAY_TARGET:-<空>}"
		err_print "可用 Profile：${coloros_profile_dirs[*]#"$patcher_dir"/profiles/}；也可用 COLOROS_DISPLAY_PROFILE 显式指定"
		exit 1
	fi
fi
profile_name="${profile_dir#"$patcher_dir"/profiles/}"
profile_display_name="$(coloros_profile_prop "$profile_dir/profile.props" display_name)"
profile_panel_table="$(coloros_profile_prop "$profile_dir/profile.props" panel_table)"
profile_disable_high_pwm_rgb="$(coloros_profile_prop "$profile_dir/profile.props" disable_high_pwm_rgb)"
profile_dark_anchor="$(coloros_profile_prop "$profile_dir/profile.props" dark_anchor_value)"
fusion_manifest="$profile_dir/config/fusionlight_files.tsv"
rro_manifest="$profile_dir/config/display_rro_files.tsv"

std_print "接入 $profile_display_name ColorOS displayconfig（Profile：$profile_name）"
std_print "来源：底包 vendor/etc/displayconfig 与 my_product 取材；目标：product 与 vendor 双路径"
std_print "完整替换 product 旧显示配置，保留底包 vendor 的原生显示库与 hals.conf"
std_print

for part_name in vendor product system_ext; do
	check_part_exists "$part_name"
done

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
vendor_displayconfig="$project_dir/vendor/etc/displayconfig"
product_displayconfig="$project_dir/product/etc/displayconfig"
vendor_contexts="$(get_part_contexts_path vendor)"
product_contexts="$(get_part_contexts_path product)"
system_ext_contexts="$(get_part_contexts_path system_ext)"
vendor_fsconfig="$(get_part_fsconfig_path vendor)"
product_fsconfig="$(get_part_fsconfig_path product)"
system_ext_fsconfig="$(get_part_fsconfig_path system_ext)"
my_product_contexts="$(get_part_contexts_path my_product)"
my_product_fsconfig="$(get_part_fsconfig_path my_product)"
target_display_id="${PORT_TARGET_DISPLAY_ID:-}"
vendor_target_display_config="$vendor_displayconfig/display_id_${target_display_id}.xml"
product_target_display_config="$product_displayconfig/display_id_${target_display_id}.xml"
my_product_dir="$project_dir/my_product"
my_product_vendor_etc="$my_product_dir/vendor/etc"
brightness_panel_source="${COLOROS_BRIGHTNESS_PANEL_SOURCE:-$my_product_dir/vendor/etc/$profile_panel_table}"
if [[ -z "$profile_panel_table" ]] || [[ "$profile_panel_table" =~ / ]]; then
	err_print "Profile $profile_name 的 panel_table 无效：${profile_panel_table:-<空>}"
	exit 1
fi
brightness_lux_source="${COLOROS_BRIGHTNESS_LUX_SOURCE:-$my_product_dir/vendor/etc/multimedia_display_brightness_config.xml}"
brightness_generator="$patcher_dir/generate_displayconfig.py"

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

for required_file in \
	"$vendor_contexts" "$product_contexts" "$system_ext_contexts" \
	"$vendor_fsconfig" "$product_fsconfig" "$system_ext_fsconfig" \
	"$my_product_contexts" "$my_product_fsconfig"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "显示配置元数据不能是符号链接：$required_file"
		exit 1
	fi
done
if [[ ! -d "$vendor_displayconfig" || -L "$vendor_displayconfig" ]]; then
	err_print "底包 vendor 显示配置目录不存在或不是普通目录：$vendor_displayconfig"
	exit 1
fi
if [[ -e "$product_displayconfig" || -L "$product_displayconfig" ]]; then
	if [[ ! -d "$product_displayconfig" || -L "$product_displayconfig" ]]; then
		err_print "原包 product 显示配置路径不是普通目录：$product_displayconfig"
		exit 1
	fi
fi

for target_path in "$vendor_target_display_config" "$product_target_display_config"; do
	if [[ -d "$target_path" ]]; then
		err_print "目标 Display ID 配置不能是目录：$target_path"
		exit 1
	fi
	if [[ -L "$target_path" ]]; then
		err_print "目标 Display ID 配置不能是符号链接：$target_path"
		exit 1
	fi
done

# 7z 资料包要求按 Android 真实路径布置 displayconfig；这里不导入资料包
# 中的一加 13 文件，而是从当前底包选择同一套 displayConfiguration 作为来源。
declare -a temporary_files=()
declare -a temporary_directories=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
	if (( ${#temporary_directories[@]} > 0 )); then
		for temporary_directory in "${temporary_directories[@]}"; do
			find "$temporary_directory" -depth -delete >/dev/null 2>&1 || true
		done
	fi
}
trap cleanup EXIT

# my_product 是底包的 ColorOS 定制取材分区，不作为最终运行时挂载点。
# 按用户要求直接覆盖合并其 vendor/etc 到最终 vendor/etc，并完整转换 metadata。
if [[ ! -d "$my_product_vendor_etc" || -L "$my_product_vendor_etc" ]]; then
	err_print "my_product vendor/etc 不存在或不是普通目录：$my_product_vendor_etc"
	exit 1
fi
merge_tree "$my_product_vendor_etc" "$project_dir/vendor/etc"
merge_translated_contexts_prefix \
	"$my_product_contexts" "$vendor_contexts" \
	/my_product/vendor/etc /vendor/etc
merge_translated_fsconfig_prefix \
	"$my_product_fsconfig" "$vendor_fsconfig" \
	my_product/vendor/etc vendor/etc
std_print "✅ 已从 my_product/vendor/etc 覆盖合并到底包 vendor/etc"

declare -a display_candidates=()
mapfile -t display_candidates < <(
	find "$vendor_displayconfig" -mindepth 1 -maxdepth 1 \
		-type f -name 'display_id_*.xml' -print | LC_ALL=C sort
)
if (( ${#display_candidates[@]} == 0 )); then
	err_print "底包 vendor 显示配置目录中没有 display_id_*.xml"
	exit 1
fi
source_display_config="$vendor_target_display_config"
if [[ ! -f "$source_display_config" ]]; then
	source_display_config="${display_candidates[0]}"
fi
if [[ -L "$source_display_config" || ! -f "$source_display_config" ]]; then
	err_print "选中的底包显示配置不是普通文件：$source_display_config"
	exit 1
fi

# my_product 只作为底包取材源；生成物必须落到最终 vendor/product，不能
# 依赖运行时挂载 ColorOS 定制分区。两份官方表均存在时才生成自动亮度表。
if [[ -f "$brightness_panel_source" && -f "$brightness_lux_source" ]]; then
	if [[ -L "$brightness_panel_source" || -L "$brightness_lux_source" ]]; then
		err_print "亮度表来源不能是符号链接"
		exit 1
	fi
	brightness_generated_dir="$(mktemp -d "$(get_config_path '.coloros_display_brightness.XXXXXX')")"
	temporary_directories+=("$brightness_generated_dir")
	brightness_generated="$brightness_generated_dir/display_id_${target_display_id}.xml"
	# Profile 未设 dark_anchor_value 时显式关闭重映射，保留上游曲线。
	brightness_generator_args=()
	if [[ -n "$profile_dark_anchor" ]]; then
		brightness_generator_args+=(--min-visible-value "$profile_dark_anchor")
	else
		brightness_generator_args+=(--no-dark-anchor)
	fi
	python3 "$brightness_generator" \
		--panel "$brightness_panel_source" \
		--lux "$brightness_lux_source" \
		--output "$brightness_generated" \
		--display-id "$target_display_id" \
		--hbm-enter-lux "${COLOROS_HBM_ENTER_LUX:-40000}" \
		"${brightness_generator_args[@]}"
	replace_file_if_different "$brightness_generated" "$vendor_target_display_config"
	source_display_config="$vendor_target_display_config"
	std_print "✅ 已从 my_product 官方亮度表生成 DisplayDeviceConfig"
else
	warn_print "my_product 缺少官方亮度表，保留底包 displayconfig：$brightness_panel_source / $brightness_lux_source"
fi

# ColorOS 的 Dolby 组件会在多个 namespace 逐级寻找配置。资料包只提供了
# 一加 13 的同名文件，不能直接带入一加 15；这里把底包已有的两套 schema
# 放到它们在参考安装脚本中对应的 fallback 路径。没有对应来源/分区时只跳过
# 该路径，其余 displayconfig 流程继续。
merge_dolby_metadata_entry() {
	local contexts_file="${1:-}"
	local fsconfig_file="${2:-}"
	local context_path="${3:-}"
	local context_value="${4:-}"
	local fsconfig_path="${5:-}"
	local uid="${6:-0}"
	local gid="${7:-0}"
	local mode="${8:-0644}"
	local contexts_patch
	local fsconfig_patch

	contexts_patch="$(mktemp "$(get_config_path '.coloros_display_dolby_contexts.XXXXXX')")"
	fsconfig_patch="$(mktemp "$(get_config_path '.coloros_display_dolby_fsconfig.XXXXXX')")"
	temporary_files+=("$contexts_patch" "$fsconfig_patch")
	printf '%s %s\n' "$context_path" "$context_value" > "$contexts_patch"
	printf '%s %s %s %s\n' "$fsconfig_path" "$uid" "$gid" "$mode" > "$fsconfig_patch"
	merge_contexts_file "$contexts_patch" "$contexts_file"
	merge_fsconfig_file "$fsconfig_patch" "$fsconfig_file"
}

ensure_dolby_directory() {
	local target_part="${1:-}"
	local relative_path="${2:-}"
	local context_path="${3:-}"
	local context_value="${4:-}"
	local fsconfig_path="${5:-}"
	local target_root="$project_dir/$target_part"
	local target_dir="$target_root/$relative_path"
	local parent_dir
	local contexts_file
	local fsconfig_file

	if [[ ! -d "$target_root" || -L "$target_root" ]]; then
		warn_print "Dolby 目标分区不存在，跳过目录：$target_part"
		return 0
	fi
	parent_dir="$(dirname -- "$target_dir")"
	if [[ ! -d "$parent_dir" || -L "$parent_dir" ]]; then
		warn_print "Dolby 目标父目录不存在，跳过目录：$target_dir"
		return 0
	fi
	if [[ -L "$target_dir" || ( -e "$target_dir" && ! -d "$target_dir" ) ]]; then
		err_print "Dolby 目标目录类型无效：$target_dir"
		return 1
	fi
	if ! contexts_file="$(get_part_contexts_path "$target_part")" || \
		! fsconfig_file="$(get_part_fsconfig_path "$target_part")"; then
		warn_print "Dolby 目标分区 metadata 路径不可用，跳过目录：$target_dir"
		return 0
	fi
	for metadata_file in "$contexts_file" "$fsconfig_file"; do
		if [[ ! -f "$metadata_file" ]]; then
			warn_print "Dolby 目标 metadata 不存在，跳过目录：$metadata_file"
			return 0
		fi
		if [[ -L "$metadata_file" ]]; then
			err_print "Dolby 目标 metadata 不能是符号链接：$metadata_file"
			return 1
		fi
	done
	if [[ ! -d "$target_dir" ]]; then
		mkdir -p -- "$target_dir"
		chmod 0755 -- "$target_dir"
	fi
	merge_dolby_metadata_entry \
		"$contexts_file" "$fsconfig_file" "$context_path" "$context_value" \
		"$fsconfig_path" 0 0 0755
}

install_dolby_file() {
	local source_file="${1:-}"
	local target_part="${2:-}"
	local relative_path="${3:-}"
	local context_path="${4:-}"
	local context_value="${5:-}"
	local target_root="$project_dir/$target_part"
	local target_file="$target_root/$relative_path"
	local parent_dir
	local contexts_file
	local fsconfig_file

	if [[ ! -e "$source_file" ]]; then
		warn_print "Dolby 来源不存在，跳过：${source_file#"$project_dir"/}"
		return 0
	fi
	if [[ -L "$source_file" || ! -f "$source_file" ]]; then
		err_print "Dolby 来源不是普通文件：$source_file"
		return 1
	fi
	if [[ ! -d "$target_root" || -L "$target_root" ]]; then
		warn_print "Dolby 目标分区不存在，跳过：$target_part"
		return 0
	fi
	if ! contexts_file="$(get_part_contexts_path "$target_part")" || \
		! fsconfig_file="$(get_part_fsconfig_path "$target_part")"; then
		warn_print "Dolby 目标分区 metadata 路径不可用，跳过：$target_file"
		return 0
	fi
	for metadata_file in "$contexts_file" "$fsconfig_file"; do
		if [[ ! -f "$metadata_file" ]]; then
			warn_print "Dolby 目标 metadata 不存在，跳过：$target_file"
			return 0
		fi
		if [[ -L "$metadata_file" ]]; then
			err_print "Dolby 目标 metadata 不能是符号链接：$metadata_file"
			return 1
		fi
	done
	if [[ -L "$target_file" || -d "$target_file" ]]; then
		err_print "Dolby 目标文件类型无效：$target_file"
		return 1
	fi
	parent_dir="$(dirname -- "$target_file")"
	if [[ ! -d "$parent_dir" || -L "$parent_dir" ]]; then
		warn_print "Dolby 目标父目录不存在，跳过：$target_file"
		return 0
	fi

	replace_file_if_different "$source_file" "$target_file"
	merge_dolby_metadata_entry \
		"$contexts_file" "$fsconfig_file" "$context_path" "$context_value" \
		"$target_part/$relative_path" 0 0 0644
	std_print "✅ Dolby fallback：${target_file#"$project_dir"/}"
}

disable_incompatible_qti_testscripts() {
	local qcom_rc="$project_dir/vendor/etc/init/hw/init.qcom.rc"
	local ufs_rc="$project_dir/vendor/etc/init/hw/init.qti.ufs.rc"
	local temporary_rc
	local active_count
	local rc_file

	for rc_file in "$qcom_rc" "$ufs_rc"; do
		if [[ ! -f "$rc_file" || -L "$rc_file" ]]; then
			warn_print "qti-testscripts RC 不存在或不是普通文件，跳过：$rc_file"
			continue
		fi
		if [[ "$rc_file" == "$qcom_rc" ]]; then
			active_count="$(grep -Ec '^[[:space:]]*start[[:space:]]+qti-testscripts[[:space:]]*$' "$rc_file" || true)"
			active_count="${active_count:-0}"
			if [[ "$active_count" == "0" ]]; then
				skip_print "qti-testscripts service 已禁用"
				continue
			fi
			if [[ "$active_count" != "1" ]]; then
				err_print "qti-testscripts 启动项数量异常：$active_count"
				return 1
			fi
			temporary_rc="$(mktemp "$(get_config_path '.coloros_display_qti_testscripts.XXXXXX')")"
			temporary_files+=("$temporary_rc")
			sed -E 's/^([[:space:]]*)start[[:space:]]+qti-testscripts[[:space:]]*$/\1# start qti-testscripts/' \
				"$rc_file" > "$temporary_rc"
		else
			active_count="$(grep -Ec '^[[:space:]]*exec[[:space:]]+u:r:vendor-qti-testscripts:s0[[:space:]]+--' "$rc_file" || true)"
			active_count="${active_count:-0}"
			if [[ "$active_count" == "0" ]]; then
				skip_print "vendor-qti-testscripts exec 已禁用"
				continue
			fi
			if [[ "$active_count" != "1" ]]; then
				err_print "vendor-qti-testscripts exec 数量异常：$active_count"
				return 1
			fi
			temporary_rc="$(mktemp "$(get_config_path '.coloros_display_qti_ufs.XXXXXX')")"
			temporary_files+=("$temporary_rc")
			sed -E 's/^([[:space:]]*)exec[[:space:]]+u:r:vendor-qti-testscripts:s0([[:space:]]+--.*)$/\1# exec u:r:vendor-qti-testscripts:s0\2/' \
				"$rc_file" > "$temporary_rc"
		fi
		replace_file_if_different "$temporary_rc" "$rc_file"
	done
	std_print "✅ 已禁用缺失 SELinux domain 的 qti-testscripts 调试入口"
}

vendor_target_contexts_patch="$(mktemp "$(get_config_path '.coloros_display_vendor_contexts.XXXXXX')")"
temporary_files+=("$vendor_target_contexts_patch")
vendor_target_fsconfig_patch="$(mktemp "$(get_config_path '.coloros_display_vendor_fsconfig.XXXXXX')")"
temporary_files+=("$vendor_target_fsconfig_patch")
product_contexts_patch="$(mktemp "$(get_config_path '.coloros_display_product_contexts.XXXXXX')")"
temporary_files+=("$product_contexts_patch")
product_fsconfig_patch="$(mktemp "$(get_config_path '.coloros_display_product_fsconfig.XXXXXX')")"
temporary_files+=("$product_fsconfig_patch")
rro_contexts_patch="$(mktemp "$(get_config_path '.coloros_display_rro_contexts.XXXXXX')")"
temporary_files+=("$rro_contexts_patch")

# RRO contexts 按机型 manifest 的目标文件名生成：来源分区的 vendor_overlay_file
# 标签不能跨到 product；最终路径沿用 product 已有的 system_file 标签。
while IFS=$'\t' read -r rro_operation rro_relative_path; do
	[[ "$rro_operation" == "#"* || -z "$rro_relative_path" ]] && continue
	rro_target_name="$(basename -- "$rro_relative_path")"
	printf '/product/overlay/%s u:object_r:system_file:s0\n' \
		"${rro_target_name//./\\.}" >> "$rro_contexts_patch"
done < "$rro_manifest"

printf '/vendor/etc/displayconfig/display_id_%s\\.xml u:object_r:vendor_configs_file:s0\n' \
	"$target_display_id" > "$vendor_target_contexts_patch"
printf 'vendor/etc/displayconfig/display_id_%s.xml 0 0 0644\n' \
	"$target_display_id" > "$vendor_target_fsconfig_patch"
printf '/product/etc/displayconfig u:object_r:system_file:s0\n' > "$product_contexts_patch"
printf '/product/etc/displayconfig/display_id_%s\\.xml u:object_r:system_file:s0\n' \
	"$target_display_id" >> "$product_contexts_patch"
printf 'product/etc/displayconfig 0 0 0755\n' > "$product_fsconfig_patch"
printf 'product/etc/displayconfig/display_id_%s.xml 0 0 0644\n' \
	"$target_display_id" >> "$product_fsconfig_patch"

# 先把目标物理 ID 别名补到底包 vendor，再以它作为 product 元数据转换输入。
replace_file_if_different "$source_display_config" "$vendor_target_display_config"
merge_contexts_file "$vendor_target_contexts_patch" "$vendor_contexts"
merge_fsconfig_file "$vendor_target_fsconfig_patch" "$vendor_fsconfig"

validate_translated_contexts_prefix \
	"$vendor_contexts" \
	/vendor/etc/displayconfig \
	/product/etc/displayconfig
validate_translated_fsconfig_prefix \
	"$vendor_fsconfig" \
	vendor/etc/displayconfig \
	product/etc/displayconfig

# ColorOS 资料包的关键点是两处目录都只保留同一套显示策略；删除原包
# product 中旧的 Xiaomi displayconfig 及其 metadata，避免多套策略抢占。
remove_part_metadata_prefix product etc/displayconfig
remove_path_if_exists "$product_displayconfig"
merge_tree "$vendor_displayconfig" "$product_displayconfig"
merge_translated_contexts_prefix_replace_context \
	"$vendor_contexts" \
	"$product_contexts" \
	/vendor/etc/displayconfig \
	/product/etc/displayconfig \
	u:object_r:vendor_configs_file:s0 \
	u:object_r:system_file:s0
merge_translated_fsconfig_prefix \
	"$vendor_fsconfig" \
	"$product_fsconfig" \
	vendor/etc/displayconfig \
	product/etc/displayconfig
merge_contexts_file "$product_contexts_patch" "$product_contexts"
merge_fsconfig_file "$product_fsconfig_patch" "$product_fsconfig"

# mi_vendor 已禁用这些入口；当前 product/vendor 未提供对应脚本和 domain，
# 强制模式下 init 的 setexeccon 会令子进程直接 SIGABRT。
disable_incompatible_qti_testscripts

# 部分机型的底包会开启 rgb 高频光感通路，移植后没有对应 sensor 服务，
# 置 1 会让自动亮度直接拉满；按 Profile 决定是否禁用。
disable_high_pwm_rgb_sensor() {
	local prop_key="ro.vendor.oplus.sensor.high_pwm_rgb"
	local build_prop
	if [[ "$profile_disable_high_pwm_rgb" != "1" ]]; then
		return 0
	fi
	for build_prop in "$project_dir/odm/build.prop" "$project_dir/odm/etc/build.prop"; do
		if [[ -L "$build_prop" ]]; then
			err_print "不支持直接修改符号链接：$build_prop"
			return 1
		elif [[ ! -e "$build_prop" ]]; then
			warn_print "自动亮度属性目标不存在，跳过：${build_prop#"$project_dir"/}"
			continue
		elif [[ ! -f "$build_prop" ]]; then
			err_print "自动亮度属性目标不是普通文件：$build_prop"
			return 1
		fi
		if grep -Eq "^[[:space:]]*${prop_key//./\\.}[[:space:]]*=" "$build_prop"; then
			comment_prop "$build_prop" "$prop_key"
			std_print "已禁用：${build_prop#"$project_dir/"} 中的 $prop_key"
		elif grep -Eq "^[[:space:]]*#[[:space:]]*${prop_key//./\\.}[[:space:]]*=" "$build_prop"; then
			skip_print "${build_prop#"$project_dir/"} 中的 $prop_key 已禁用"
		else
			warn_print "属性不存在，跳过：${build_prop#"$project_dir/"} 中的 $prop_key"
		fi
	done
}
disable_high_pwm_rgb_sensor

display_dolby_source="$project_dir/odm/etc/dolby/display/dolby_vision.cfg"
decoder_dolby_source="$project_dir/odm/etc/dolby/dolby_vision.cfg"

# 显示 schema：供 CLSTC/SurfaceFlinger 使用。
if [[ -f "$display_dolby_source" ]]; then
	ensure_dolby_directory \
		odm etc/surfaceflinger \
		'/odm/etc/surfaceflinger' \
		u:object_r:vendor_configs_file:s0 \
		odm/etc/surfaceflinger
	install_dolby_file \
		"$display_dolby_source" system system/etc/dolby_vision.cfg \
		'/system/system/etc/dolby_vision\.cfg' \
		u:object_r:system_file:s0
	install_dolby_file \
		"$display_dolby_source" product etc/dolby_vision.cfg \
		'/product/etc/dolby_vision\.cfg' \
		u:object_r:system_file:s0
	install_dolby_file \
		"$display_dolby_source" odm etc/surfaceflinger/dolby_vision.cfg \
		'/odm/etc/surfaceflinger/dolby_vision\.cfg' \
		u:object_r:vendor_configs_file:s0
else
	warn_print "底包缺少显示 Dolby 配置，跳过显示 fallback：$display_dolby_source"
fi

# 解码器 schema：供 Dolby decoder processor 的兼容路径使用。
if [[ -f "$decoder_dolby_source" ]]; then
	install_dolby_file \
		"$decoder_dolby_source" odm etc/dolby_vision.cfg \
		'/odm/etc/dolby_vision\.cfg' \
		u:object_r:vendor_configs_file:s0
	install_dolby_file \
		"$decoder_dolby_source" vendor etc/dolby_vision.cfg \
		'/vendor/etc/dolby_vision\.cfg' \
		u:object_r:vendor_configs_file:s0
	install_dolby_file \
		"$decoder_dolby_source" odm vendor/etc/dolby_vision.cfg \
		'/odm/vendor/etc/dolby_vision\.cfg' \
		u:object_r:vendor_file:s0
else
	warn_print "底包缺少解码器 Dolby 配置，跳过 decoder fallback：$decoder_dolby_source"
fi

# 若工作树已经有 persist/display 目录，也按参考安装脚本补上可达 fallback；
# 不凭空创建 persist 挂载点。
persist_dolby_source="$display_dolby_source"
if [[ -f "$project_dir/odm/vendor/persist/display/dolby_vision.cfg" ]]; then
	persist_dolby_source="$project_dir/odm/vendor/persist/display/dolby_vision.cfg"
fi
if [[ -d "$project_dir/vendor/persist/display" && \
	! -L "$project_dir/vendor/persist/display" ]]; then
	install_dolby_file \
		"$persist_dolby_source" vendor persist/display/dolby_vision.cfg \
		'/vendor/persist/display/dolby_vision\.cfg' \
		u:object_r:vendor_file:s0
fi
if [[ -d "$project_dir/odm/vendor/persist/display" && \
	! -L "$project_dir/odm/vendor/persist/display" ]]; then
	install_dolby_file \
		"$persist_dolby_source" odm vendor/persist/display/dolby_vision.cfg \
		'/odm/vendor/persist/display/dolby_vision\.cfg' \
		u:object_r:vendor_file:s0
fi

# my_product 是取材分区，最终系统不会挂载它。FusionLight profile 因此迁移到
# ColorOS 参考布局使用的 system_ext/etc；清单同时约束两个屏厂配置及其 metadata。
validate_source_file_manifest "$my_product_dir" "$project_dir/system_ext" "$fusion_manifest"
validate_translated_contexts \
	"$my_product_contexts" "$fusion_manifest" /my_product /system_ext
validate_translated_fsconfig \
	"$my_product_fsconfig" "$fusion_manifest" my_product system_ext
apply_source_file_manifest "$my_product_dir" "$project_dir/system_ext" "$fusion_manifest"
fusion_target_dir="$project_dir/system_ext/etc/fusionlight_profile"
if [[ ! -d "$fusion_target_dir" || -L "$fusion_target_dir" ]]; then
	err_print "FusionLight 目标目录不存在或不是普通目录：$fusion_target_dir"
	exit 1
fi
chmod 0755 -- "$fusion_target_dir"
merge_translated_contexts_prefix \
	"$my_product_contexts" "$system_ext_contexts" \
	/my_product/etc/fusionlight_profile /system_ext/etc/fusionlight_profile
merge_translated_fsconfig_prefix \
	"$my_product_fsconfig" "$system_ext_fsconfig" \
	my_product/etc/fusionlight_profile system_ext/etc/fusionlight_profile

# 两个底包静态 RRO 原名放到最终 product/overlay。来源分区的
# vendor_overlay_file 标签不能跨到 product；最终路径沿用 product 已有的
# system_file 标签，fsconfig 则直接继承原包 0644 条目。
validate_source_file_manifest "$my_product_dir" "$project_dir/product" "$rro_manifest"
validate_translated_contexts \
	"$my_product_contexts" "$rro_manifest" /my_product /product
validate_translated_fsconfig \
	"$my_product_fsconfig" "$rro_manifest" my_product product
apply_source_file_manifest "$my_product_dir" "$project_dir/product" "$rro_manifest"
merge_contexts_file "$rro_contexts_patch" "$product_contexts"
merge_translated_fsconfig \
	"$my_product_fsconfig" "$product_fsconfig" my_product product "$rro_manifest"

display_count="${#display_candidates[@]}"
std_print "✅ 已从底包同步 $display_count 个 display_id 配置到 product"
std_print "✅ 目标 Display ID：$target_display_id（来源：$(basename -- "$source_display_config")）"
std_print "✅ product/vendor displayconfig 与 contexts/fsconfig 已同步"
std_print "✅ 已按底包现有 schema 接入 Dolby visual fallback（不含 Dolby 音频）"
std_print "✅ 已迁移 $profile_display_name FusionLight profile 到 system_ext/etc"
std_print "✅ 已安装 $profile_display_name android/oplus display RRO 到 product/overlay"
std_print "✅ CWB AIDL、VINTF 与 32/64 位原生库继续直接采用底包 odm/vendor 文件"
std_print "处理完成"
