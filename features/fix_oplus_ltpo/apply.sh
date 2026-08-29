#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
jar_staging_dir=''
apollo_staging_dir=''

cleanup_staging_dirs() {
	local staging_dir

	for staging_dir in "$jar_staging_dir" "$apollo_staging_dir"; do
		if [[ -n "$staging_dir" && -d "$staging_dir" ]]; then
			find "$staging_dir" -depth -delete >/dev/null 2>&1 || true
		fi
	done
}

init_port_env "${1:-}"

std_print "修正 MI SurfaceFlinger 与 Oplus ADFR LTPO 链路"
std_print "补齐 ODM property contexts、automode 与 VRR/self-refresh 配置"
std_print "注意：不替换面板/HWC 实现，不猜写 idle 1/55Hz 数值；仅对已校验的 Apollo 路径做定点适配"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
odm_build_prop="$project_dir/odm/etc/build.prop"
vendor_build_prop="$project_dir/vendor/build.prop"
odm_selinux_dir="$project_dir/odm/etc/selinux"
odm_property_contexts="$odm_selinux_dir/odm_property_contexts"
odm_metadata_contexts="$(get_part_contexts_path odm)"
odm_metadata_fsconfig="$(get_part_fsconfig_path odm)"
property_context_fragment="$patcher_dir/config/odm_property_contexts"
metadata_context_fragment="$patcher_dir/config/odm_metadata_contexts"
metadata_fsconfig_fragment="$patcher_dir/config/odm_fsconfig"
miui_services_patcher="$patcher_dir/patch_miui_services_adfr.sh"
miui_services_jar="$project_dir/system_ext/framework/miui-services.jar"
oplus_adfr_rus_xml="${OPLUS_ADFR_RUS_XML_FILE:-}"
apollo_patcher="$patcher_dir/patch_apollo_panel_nit.py"
apollo_asset="${OPLUS_APOLLO_PANEL_CONFIG_ASSET:-}"
apollo_relative_path="${OPLUS_APOLLO_PANEL_CONFIG_RELATIVE_PATH:-}"
apollo_xml_sha256="${OPLUS_APOLLO_PANEL_CONFIG_SHA256:-}"
apollo_enabled=0
staged_apollo_xml=''
staged_apollo_sdmcore=''
apollo_input_snapshot=''
apollo_xml_target=''
apollo_sdmcore_target="$project_dir/vendor/lib64/libsdmcore.so"
apollo_vendor_contexts=''
apollo_vendor_fsconfig=''
temporary_vendor_contexts=''
temporary_vendor_fsconfig=''

for required_file in \
	"$property_context_fragment" \
	"$metadata_context_fragment" \
	"$metadata_fsconfig_fragment" \
	"$odm_metadata_contexts" \
	"$odm_metadata_fsconfig"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "LTPO contexts/metadata 输入不能是符号链接：$required_file"
		exit 1
	fi
done

if [[ -L "$odm_selinux_dir" || ! -d "$odm_selinux_dir" ]]; then
	err_print "ODM SELinux 目录不存在或不是普通目录：$odm_selinux_dir"
	exit 1
fi
if [[ -L "$odm_property_contexts" ]]; then
	err_print "ODM property contexts 不能是符号链接：$odm_property_contexts"
	exit 1
elif [[ -e "$odm_property_contexts" && ! -f "$odm_property_contexts" ]]; then
	err_print "ODM property contexts 不是普通文件：$odm_property_contexts"
	exit 1
fi

if ! grep -Fqx \
	'persist.oplus.display.vrr.adfr u:object_r:exported_system_prop:s0' \
	"$property_context_fragment" || \
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$property_context_fragment") != 1 )); then
	err_print "LTPO property contexts 片段必须只声明 persist.oplus.display.vrr.adfr"
	exit 1
fi
if ! grep -Fqx \
	'/odm/etc/selinux/odm_property_contexts u:object_r:property_contexts_file:s0' \
	"$metadata_context_fragment" || \
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$metadata_context_fragment") != 1 )); then
	err_print "LTPO ODM contexts 片段不完整"
	exit 1
fi
if ! grep -Fqx \
	'odm/etc/selinux/odm_property_contexts 0 0 0644' \
	"$metadata_fsconfig_fragment" || \
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$metadata_fsconfig_fragment") != 1 )); then
	err_print "LTPO ODM fsconfig 片段不完整"
	exit 1
fi

if [[ -L "$odm_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$odm_build_prop"
	exit 1
elif [[ ! -e "$odm_build_prop" ]]; then
	warn_print "LTPO 属性目标不存在，跳过：${odm_build_prop#"$project_dir"/}"
	std_print "处理完成"
	exit 0
elif [[ ! -f "$odm_build_prop" ]]; then
	err_print "LTPO 属性目标不是普通文件：$odm_build_prop"
	exit 1
fi

temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
	cleanup_staging_dirs
}
trap cleanup EXIT

remove_prop() {
	local file_path="${1:-}"
	local prop_key="${2:-}"
	local temporary_file

	if [[ -z "$file_path" || -z "$prop_key" ]]; then
		err_print "删除属性参数不完整"
		return 1
	fi
	temporary_file="$(mktemp "${file_path}.tmp.XXXXXX")"
	temporary_files+=("$temporary_file")
	# 删除同名属性及其注释残留，避免旧补丁产物继续启用不兼容路径。
	# shellcheck disable=SC2016 # awk 脚本故意使用 ENVIRON，避免 Shell 展开。
	if ! env PORT_PROP_KEY="$prop_key" awk '
		BEGIN { key = ENVIRON["PORT_PROP_KEY"] }
		function line_key(line, candidate, separator) {
			candidate = line
			sub(/^[[:space:]]*/, "", candidate)
			if (substr(candidate, 1, 1) == "#") {
				candidate = substr(candidate, 2)
				sub(/^[[:space:]]*/, "", candidate)
			}
			separator = index(candidate, "=")
			if (separator == 0) return ""
			candidate = substr(candidate, 1, separator - 1)
			sub(/[[:space:]]*$/, "", candidate)
			return candidate
		}
		line_key($0) != key { print }
	' "$file_path" > "$temporary_file"; then
		err_print "删除属性失败：$prop_key"
		return 1
	fi
	_install_generated_file "$temporary_file" "$file_path"
}

prepare_apollo_panel_nit() {
	local -a apollo_config_values=(
		"$apollo_asset"
		"$apollo_relative_path"
		"$apollo_xml_sha256"
	)
	local apollo_config_present=0
	local value
	local vendor_contexts
	local vendor_fsconfig
	local apollo_context_relative
	local apollo_context_patch
	local apollo_fsconfig_patch

	for value in "${apollo_config_values[@]}"; do
		if [[ -n "$value" ]]; then
			((apollo_config_present += 1))
		fi
	done
	if (( apollo_config_present == 0 )); then
		return 0
	fi
	if (( apollo_config_present != ${#apollo_config_values[@]} )); then
		err_print "Apollo panel-nit 参数必须由机型组合入口完整提供或全部省略"
		return 1
	fi
	if [[ ! "$apollo_relative_path" =~ ^etc/display_apollo_list_[A-Za-z0-9_]+\.xml$ ]]; then
		err_print "Apollo panel-nit 目标路径不受支持：$apollo_relative_path"
		return 1
	fi
	if [[ ! "$apollo_xml_sha256" =~ ^[0-9a-f]{64}$ ]]; then
		err_print "Apollo 项目 asset SHA-256 格式无效"
		return 1
	fi

	check_file_exists "$apollo_patcher"
	check_file_exists "$apollo_asset"
	if [[ -L "$apollo_patcher" || -L "$apollo_asset" || ! -f "$apollo_patcher" || ! -f "$apollo_asset" ]]; then
		err_print "Apollo patcher 与 asset 必须是普通文件"
		return 1
	fi
	if [[ -L "$apollo_sdmcore_target" ]]; then
		err_print "不支持修补符号链接 libsdmcore.so：$apollo_sdmcore_target"
		return 1
	elif [[ ! -e "$apollo_sdmcore_target" ]]; then
		warn_print "Apollo 目标库不存在，跳过 panel-nit 修补：${apollo_sdmcore_target#"$project_dir"/}"
		return 0
	elif [[ ! -f "$apollo_sdmcore_target" ]]; then
		err_print "Apollo 目标库不是普通文件：$apollo_sdmcore_target"
		return 1
	fi
	if [[ -L "$project_dir/vendor/etc" || ! -d "$project_dir/vendor/etc" ]]; then
		err_print "vendor/etc 不存在或不是普通目录，不能安装 Apollo XML"
		return 1
	fi

	check_part_exists vendor
	vendor_contexts="$(get_part_contexts_path vendor)"
	vendor_fsconfig="$(get_part_fsconfig_path vendor)"
	check_file_exists "$vendor_contexts"
	check_file_exists "$vendor_fsconfig"
	check_partition_metadata_tool >/dev/null
	if [[ -L "$vendor_contexts" || -L "$vendor_fsconfig" ]]; then
		err_print "Apollo vendor metadata 不能是符号链接"
		return 1
	fi
	apollo_vendor_contexts="$vendor_contexts"
	apollo_vendor_fsconfig="$vendor_fsconfig"

	apollo_staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/fix-ltpo-apollo.apply.XXXXXX")
	staged_apollo_xml="$apollo_staging_dir/display_apollo.xml"
	staged_apollo_sdmcore="$apollo_staging_dir/libsdmcore.so"
	apollo_input_snapshot="$apollo_staging_dir/libsdmcore.input"
	cp -p -- "$apollo_sdmcore_target" "$apollo_input_snapshot"
	apollo_xml_target="$project_dir/vendor/$apollo_relative_path"
	if [[ -L "$apollo_xml_target" ]]; then
		err_print "不支持替换符号链接 Apollo XML：$apollo_xml_target"
		return 1
	elif [[ -e "$apollo_xml_target" && ! -f "$apollo_xml_target" ]]; then
		err_print "Apollo XML 目标不是普通文件：$apollo_xml_target"
		return 1
	fi
	if ! python3 "$apollo_patcher" \
		--asset "$apollo_asset" \
		--output-xml "$staged_apollo_xml" \
		--xml-sha256 "$apollo_xml_sha256" \
		--input-library "$apollo_sdmcore_target" \
		--output-library "$staged_apollo_sdmcore"; then
		err_print "Apollo panel-nit staging 校验失败"
		return 1
	fi
	if ! cmp -s -- "$apollo_input_snapshot" "$apollo_sdmcore_target"; then
		err_print "Apollo staging 输入在解析期间发生变化"
		return 1
	fi

	apollo_context_relative="${apollo_relative_path//./\\.}"
	apollo_context_patch="$(mktemp "$(get_config_path '.fix_oplus_ltpo_apollo_contexts.XXXXXX')")"
	apollo_fsconfig_patch="$(mktemp "$(get_config_path '.fix_oplus_ltpo_apollo_fsconfig.XXXXXX')")"
	temporary_vendor_contexts="$(mktemp "$(get_config_path '.fix_oplus_ltpo_vendor_contexts.XXXXXX')")"
	temporary_vendor_fsconfig="$(mktemp "$(get_config_path '.fix_oplus_ltpo_vendor_fsconfig.XXXXXX')")"
	temporary_files+=(
		"$apollo_context_patch"
		"$apollo_fsconfig_patch"
		"$temporary_vendor_contexts"
		"$temporary_vendor_fsconfig"
	)
	printf '/vendor/%s u:object_r:vendor_configs_file:s0\n' "$apollo_context_relative" > "$apollo_context_patch"
	printf 'vendor/%s 0 0 0644\n' "$apollo_relative_path" > "$apollo_fsconfig_patch"
	cp -p -- "$vendor_contexts" "$temporary_vendor_contexts"
	cp -p -- "$vendor_fsconfig" "$temporary_vendor_fsconfig"
	merge_contexts_file "$apollo_context_patch" "$temporary_vendor_contexts"
	merge_fsconfig_file "$apollo_fsconfig_patch" "$temporary_vendor_fsconfig"
	if ! grep -Fqx "/vendor/$apollo_context_relative u:object_r:vendor_configs_file:s0" "$temporary_vendor_contexts" || \
		! grep -Fqx "vendor/$apollo_relative_path 0 0 0644" "$temporary_vendor_fsconfig"; then
		err_print "Apollo vendor metadata staging 校验失败"
		return 1
	fi
	apollo_enabled=1
}

temporary_property_contexts="$(mktemp "$(get_config_path '.fix_oplus_ltpo_property_contexts.XXXXXX')")"
temporary_odm_contexts="$(mktemp "$(get_config_path '.fix_oplus_ltpo_odm_contexts.XXXXXX')")"
temporary_odm_fsconfig="$(mktemp "$(get_config_path '.fix_oplus_ltpo_odm_fsconfig.XXXXXX')")"
temporary_odm_build_prop="$(mktemp "$(get_config_path '.fix_oplus_ltpo_odm_build_prop.XXXXXX')")"
temporary_files+=(
	"$temporary_property_contexts"
	"$temporary_odm_contexts"
	"$temporary_odm_fsconfig"
	"$temporary_odm_build_prop"
)

if [[ -e "$odm_property_contexts" ]]; then
	cp -p -- "$odm_property_contexts" "$temporary_property_contexts"
	merge_contexts_file "$property_context_fragment" "$temporary_property_contexts"
else
	cp -p -- "$property_context_fragment" "$temporary_property_contexts"
fi
chmod 0644 -- "$temporary_property_contexts"
if (( $(awk '$1 == "persist.oplus.display.vrr.adfr" { count++ } END { print count + 0 }' \
	"$temporary_property_contexts") != 1 )); then
	err_print "生成的 ODM property contexts 未形成唯一 ADFR 属性条目"
	exit 1
fi

cp -p -- "$odm_metadata_contexts" "$temporary_odm_contexts"
cp -p -- "$odm_metadata_fsconfig" "$temporary_odm_fsconfig"
merge_contexts_file "$metadata_context_fragment" "$temporary_odm_contexts"
merge_fsconfig_file "$metadata_fsconfig_fragment" "$temporary_odm_fsconfig"

cp -p -- "$odm_build_prop" "$temporary_odm_build_prop"
# 目标是 Oplus ADFR 面板；强制打开 MI LTPO 会把 144/165 带入错误的
# Xiaomi 60/120 timing-switch 路径。保留默认 false/未定义状态。
remove_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.ltpo.support
remove_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.enable_tp_idle_automode
ensure_prop "$temporary_odm_build_prop" persist.oplus.display.vrr.adfr 1
ensure_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.dynamic_skip_override_refresh_rate true
ensure_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.enable_automode_for_maxfps_setting true
ensure_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.support_automode_for_normalfps true
# MI-SF 会按该列表逐项判断当前 max-FPS 是否进入 automode；只保留
# 60/120 会让 90/144/165 直接失去 automode 资格。这里补齐底包已
# 枚举且触控链路实际使用的高刷档位，但不伪造面板低频命令。
ensure_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.supported_automode_maxfps_list 60,90,120,144,165
# 不写入 ro.vendor.mi_sf.enable_tp_idle_automode：目标 libmisurfaceflinger.so
# 在该开关为 true 时会把所有 TP-idle 请求直接改成 60Hz，屏蔽 1/55Hz
# 以及面板实际的低频匹配。support_90hz_skip_tp_idle 只保留为原包策略。
ensure_prop "$temporary_odm_build_prop" ro.vendor.mi_sf.support_90hz_skip_tp_idle true

temporary_vendor_build_prop=""

if [[ -L "$vendor_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$vendor_build_prop"
	exit 1
elif [[ -e "$vendor_build_prop" ]]; then
	if [[ ! -f "$vendor_build_prop" ]]; then
		err_print "vendor 属性目标不是普通文件：$vendor_build_prop"
		exit 1
	fi
	temporary_vendor_build_prop="$(mktemp "$(get_config_path '.fix_oplus_ltpo_vendor_build_prop.XXXXXX')")"
	temporary_files+=("$temporary_vendor_build_prop")
	cp -p -- "$vendor_build_prop" "$temporary_vendor_build_prop"
	ensure_prop "$temporary_vendor_build_prop" debug.sf.enable_vrr_config 1
	# 不写 vendor.display.enable_qsync_idle：原系统实测该属性为空但 LTPO 正常，
	# 因此它不是 OnePlus 15 ADFR 的已证实前提。目标 libsdmcore 与原系统版本
	# 不同，其可选 idle-QSync 分支不能据此作为永久策略打开。
	ensure_prop "$temporary_vendor_build_prop" vendor.display.enable_hal_self_refresh 1
else
	warn_print "vendor 属性目标不存在，跳过 VRR/self-refresh：${vendor_build_prop#"$project_dir"/}"
fi

prepare_apollo_panel_nit

_install_generated_file "$temporary_odm_build_prop" "$odm_build_prop"
if [[ -n "$temporary_vendor_build_prop" ]]; then
	_install_generated_file "$temporary_vendor_build_prop" "$vendor_build_prop"
	std_print "✅ 已启用 vendor VRR config 与 HAL self-refresh"
fi
if [[ -e "$odm_property_contexts" ]]; then
	_install_generated_file "$temporary_property_contexts" "$odm_property_contexts"
else
	replace_file_if_different "$temporary_property_contexts" "$odm_property_contexts"
	chmod 0644 -- "$odm_property_contexts"
fi
_install_generated_file "$temporary_odm_contexts" "$odm_metadata_contexts"
_install_generated_file "$temporary_odm_fsconfig" "$odm_metadata_fsconfig"
if (( apollo_enabled == 1 )); then
	replace_file_if_different "$staged_apollo_xml" "$apollo_xml_target"
	replace_file_if_different "$staged_apollo_sdmcore" "$apollo_sdmcore_target"
	chmod 0644 -- "$apollo_xml_target" "$apollo_sdmcore_target"
	_install_generated_file "$temporary_vendor_contexts" "$apollo_vendor_contexts"
	_install_generated_file "$temporary_vendor_fsconfig" "$apollo_vendor_fsconfig"
	if ! cmp -s -- "$staged_apollo_xml" "$apollo_xml_target" ||
		! cmp -s -- "$staged_apollo_sdmcore" "$apollo_sdmcore_target"; then
		err_print "Apollo panel-nit 安装后内容校验失败"
		exit 1
	fi
	std_print "✅ 已安装 AD296 Apollo panel-nit XML，并定点适配 libsdmcore 路径"
	std_print "✅ 已同步 Apollo XML 的 vendor contexts 与 fsconfig"
fi

std_print "✅ 已保持 MI LTPO 关闭，写入 Oplus ADFR 与 MI-SF automode 开关"
std_print "✅ 已生成 /odm/etc/selinux/odm_property_contexts 并补齐 ODM metadata"

# 原厂由 system_server 在 boot complete 后将固定格式的 ADFR RUS 配置发送给
# Oplus panel-feature 服务。移植 system_server 缺少该调用者，底层 plugin 因而
# 未拿到 min-fps 向量。这里仅在机型组合入口显式提供并通过校验的 XML 存在时，
# 在 staging JAR 中注入一次等价的 feature=234 Binder 调用。
if [[ -L "$miui_services_jar" ]]; then
	err_print "不支持修改符号链接 miui-services.jar：$miui_services_jar"
	exit 1
elif [[ ! -e "$miui_services_jar" ]]; then
	warn_print "miui-services.jar 不存在，跳过 OnePlus ADFR RUS loader：${miui_services_jar#"$project_dir"/}"
elif [[ ! -f "$miui_services_jar" ]]; then
	err_print "miui-services.jar 不是普通文件：$miui_services_jar"
	exit 1
elif [[ -z "$oplus_adfr_rus_xml" ]]; then
	warn_print "未设置 OPLUS_ADFR_RUS_XML_FILE，跳过 OnePlus ADFR RUS loader"
elif [[ -L "$oplus_adfr_rus_xml" || ! -f "$oplus_adfr_rus_xml" ]]; then
	err_print "OnePlus ADFR RUS XML 不存在、不是普通文件或为符号链接：$oplus_adfr_rus_xml"
	exit 1
else
	check_file_exists "$miui_services_patcher"
	check_part_exists system_ext
	check_file_exists "$(get_part_contexts_path system_ext)"
	check_file_exists "$(get_part_fsconfig_path system_ext)"
	check_partition_metadata_tool >/dev/null

	jar_staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/fix-ltpo-adfr-rus.apply.XXXXXX")
	staged_miui_services_jar="$jar_staging_dir/miui-services.jar"
	cp -a -- "$miui_services_jar" "$staged_miui_services_jar"
	bash "$miui_services_patcher" "$staged_miui_services_jar" "$oplus_adfr_rus_xml"

	if ! cmp -s "$staged_miui_services_jar" "$miui_services_jar"; then
		replace_file_if_different "$staged_miui_services_jar" "$miui_services_jar"

		stale_runtime_files=(
			framework/miui-services.jar.fsv_meta
			framework/miui-services.jar.prof
			framework/miui-services.jar.prof.fsv_meta
		)
		for abi in arm arm64; do
			for variant in autoui hovermode hyperviewscale thirdappopt; do
				for extension in odex odex.fsv_meta vdex vdex.fsv_meta; do
					stale_runtime_files+=("framework/oat/$abi/miui-services.$variant.$extension")
				done
			done
		done
		for relative_path in "${stale_runtime_files[@]}"; do
			if [[ -e "$project_dir/system_ext/$relative_path" || -L "$project_dir/system_ext/$relative_path" ]]; then
				remove_path_if_exists "$project_dir/system_ext/$relative_path"
			fi
			remove_part_metadata_prefix system_ext "$relative_path"
		done
		std_print "✅ 已更新 OnePlus ADFR system_server JAR（RUS loader/旧 Full-AOD replay 清理）：system_ext/framework/miui-services.jar"
		std_print "✅ 已清理目标 JAR 的旧 profile、FS-Verity 元数据与分 ABI 预编译产物"
	else
		std_print "✅ OnePlus ADFR RUS loader 已存在，保留现有 miui-services.jar"
	fi
fi

std_print "处理完成"
