#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "接入 HyperOS 双击亮屏到 Oplus HBP 触控栈"
std_print "Xiaomi TouchFeature mode 14 经独立 AIDL bridge 转发到底包 IOplusTouch"
std_print "双击手势输入使用设备专属 WAKE keylayout，不修改全局 Generic.kl"
std_print

parameter_file="${OPLUS_DOUBLE_TAP_PROPERTIES_FILE:-}"
bridge_source="$patcher_dir/src/touchfeature_oplus_bridge.cpp"
bridge_header="$patcher_dir/include/platform_binder_compat.h"
bridge_build_script="$patcher_dir/build.sh"
bridge_prebuilt="$patcher_dir/prebuilt/odm/bin/hw/vendor.dna.hardware.touchfeature-oplus-bridge"
bridge_input_stamp="$bridge_prebuilt.inputs.sha256"
rc_template="$patcher_dir/config/vendor.dna.hardware.touchfeature-oplus-bridge.rc.in"
vintf_source="$patcher_dir/config/vendor.dna.hardware.touchfeature-oplus-bridge.xml"
keylayout_template="$patcher_dir/config/keylayout.kl.in"
bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
bundle_policy="$patcher_dir/config/selinux_policy.cil.in"
bundle_odm_contexts="$patcher_dir/config/touchfeature_odm_contexts"
bundle_property_contexts="$patcher_dir/config/touchfeature_property_contexts"
bundle_service_contexts="$patcher_dir/config/touchfeature_service_contexts"

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
odm_build_prop="$project_dir/odm/etc/build.prop"
odm_contexts="$(get_part_contexts_path odm)"
odm_fsconfig="$(get_part_fsconfig_path odm)"
vendor_policy="$project_dir/vendor/etc/selinux/vendor_sepolicy.cil"
vendor_plat_policy="$project_dir/vendor/etc/selinux/plat_pub_versioned.cil"
vendor_service_contexts="$project_dir/vendor/etc/selinux/vendor_service_contexts"
precompiled_file_contexts="$project_dir/odm/etc/selinux/precompiled_file_contexts"
oplus_touch_rc="$project_dir/odm/etc/init/vendor-oplus-hardware-touch-V2-hbp5-service.rc"
oplus_touch_manifest="$project_dir/odm/etc/vintf/manifest/manifest_touch_aidl.xml"
oplus_touch_service="$project_dir/odm/bin/hw/vendor-oplus-hardware-touch-V2-hbp5-service"
oplus_touch_ndk="$project_dir/odm/lib64/vendor.oplus.hardware.touch-V2-ndk.so"
system_binder_ndk="$project_dir/system/system/lib64/libbinder_ndk.so"
miui_framework="$project_dir/system_ext/framework/miui-framework.jar"
miui_services="$project_dir/system_ext/framework/miui-services.jar"

if [[ -z "$parameter_file" ]]; then
	err_print "缺少目标设备双击亮屏参数配置：OPLUS_DOUBLE_TAP_PROPERTIES_FILE"
	exit 1
elif [[ -L "$parameter_file" ]]; then
	err_print "双击亮屏参数配置不能是符号链接：$parameter_file"
	exit 1
elif [[ ! -e "$parameter_file" ]]; then
	err_print "双击亮屏参数配置不存在：$parameter_file"
	exit 1
elif [[ ! -f "$parameter_file" ]]; then
	err_print "双击亮屏参数配置不是普通文件：$parameter_file"
	exit 1
fi
validate_prop_file "$parameter_file"

expected_parameters=(
	oplus.double_tap.panel_id
	oplus.double_tap.gesture_cfg_node
	oplus.double_tap.gesture_enable_node
	oplus.double_tap.gesture_cfg_value
	oplus.double_tap.input_device_name
	oplus.double_tap.scan_code
	oplus.double_tap.touchfeature_type
)
declare -A expected_parameter_set=()
for parameter_name in "${expected_parameters[@]}"; do
	expected_parameter_set["$parameter_name"]=1
done

parameter_count=0
while IFS= read -r parameter_line || [[ -n "$parameter_line" ]]; do
	parameter_line="${parameter_line%$'\r'}"
	parameter_line="${parameter_line#"${parameter_line%%[![:space:]]*}"}"
	[[ -z "$parameter_line" || "$parameter_line" == \#* ]] && continue
	parameter_name="${parameter_line%%=*}"
	parameter_name="${parameter_name%"${parameter_name##*[![:space:]]}"}"
	if [[ -z "${expected_parameter_set[$parameter_name]+present}" ]]; then
		err_print "双击亮屏参数配置包含未知属性：$parameter_name"
		exit 1
	fi
	parameter_count=$((parameter_count + 1))
done < "$parameter_file"
if (( parameter_count != ${#expected_parameters[@]} )); then
	err_print "双击亮屏参数配置必须恰好包含 ${#expected_parameters[@]} 项"
	exit 1
fi

read_required_parameter() {
	local property_name="${1:-}"
	local property_value
	if ! property_value="$(read_prop_value "$property_name" "$parameter_file")"; then
		err_print "双击亮屏参数配置缺少属性：$property_name"
		return 1
	fi
	if [[ -z "$property_value" ]]; then
		err_print "双击亮屏参数配置的属性值为空：$property_name"
		return 1
	fi
	printf '%s\n' "$property_value"
}

require_integer_range() {
	local description="${1:-}"
	local value="${2:-}"
	local minimum="${3:-0}"
	local maximum="${4:-2147483647}"
	if [[ ! "$value" =~ ^[0-9]+$ ]] || \
		(( 10#$value < minimum || 10#$value > maximum )); then
		err_print "$description 不是范围 ${minimum}..${maximum} 内的整数：$value"
		return 1
	fi
}

panel_id="$(read_required_parameter oplus.double_tap.panel_id)"
gesture_cfg_node="$(read_required_parameter oplus.double_tap.gesture_cfg_node)"
gesture_enable_node="$(read_required_parameter oplus.double_tap.gesture_enable_node)"
gesture_cfg_value="$(read_required_parameter oplus.double_tap.gesture_cfg_value)"
input_device_name="$(read_required_parameter oplus.double_tap.input_device_name)"
scan_code="$(read_required_parameter oplus.double_tap.scan_code)"
touchfeature_type="$(read_required_parameter oplus.double_tap.touchfeature_type)"

require_integer_range "Oplus 面板 ID" "$panel_id" 0 31
require_integer_range "gesture_cfg 节点 ID" "$gesture_cfg_node" 1 2147483647
require_integer_range "gesture_en 节点 ID" "$gesture_enable_node" 1 2147483647
require_integer_range "gesture_cfg 开启值" "$gesture_cfg_value" 0 2147483647
require_integer_range "双击手势 scan code" "$scan_code" 1 767
require_integer_range "ro.vendor.touchfeature.type" "$touchfeature_type" 1 2147483647
if (( (10#$touchfeature_type & 1) == 0 )); then
	err_print "ro.vendor.touchfeature.type 必须包含双击唤醒能力位 0x1"
	exit 1
fi
if [[ ! "$input_device_name" =~ ^[A-Za-z0-9._-]+$ || \
	"$input_device_name" == "." || "$input_device_name" == ".." ]]; then
	err_print "输入设备名不能安全映射为 keylayout 文件：$input_device_name"
	exit 1
fi
if [[ "$gesture_cfg_node" == "$gesture_enable_node" ]]; then
	err_print "gesture_cfg 与 gesture_en 节点 ID 不能相同"
	exit 1
fi

for part_name in odm vendor system system_ext; do
	check_part_exists "$part_name"
done
check_partition_metadata_tool >/dev/null

for command_name in sha256sum file readelf; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		err_print "缺少工具，无法校验双击亮屏 bridge：$command_name"
		exit 1
	fi
done

for required_file in \
	"$bridge_source" \
	"$bridge_header" \
	"$bridge_build_script" \
	"$bridge_prebuilt" \
	"$bridge_input_stamp" \
	"$rc_template" \
	"$vintf_source" \
	"$keylayout_template" \
	"$bundle_manifest" \
	"$bundle_policy" \
	"$bundle_odm_contexts" \
	"$bundle_property_contexts" \
	"$bundle_service_contexts" \
	"$odm_build_prop" \
	"$odm_contexts" \
	"$odm_fsconfig" \
	"$vendor_policy" \
	"$vendor_plat_policy" \
	"$vendor_service_contexts" \
	"$precompiled_file_contexts" \
	"$oplus_touch_rc" \
	"$oplus_touch_manifest" \
	"$oplus_touch_service" \
	"$oplus_touch_ndk" \
	"$system_binder_ndk" \
	"$miui_framework" \
	"$miui_services"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "双击亮屏输入不能是符号链接：$required_file"
		exit 1
	fi
done

calculate_bridge_input_hash() {
	sha256sum \
		"$bridge_build_script" \
		"$bridge_source" \
		"$bridge_header" | \
		awk '{print $1}' | sha256sum | awk '{print $1}'
}

read -r recorded_hash extra_hash_field < "$bridge_input_stamp" || true
if [[ ! "${recorded_hash:-}" =~ ^[0-9a-fA-F]{64}$ || \
	-n "${extra_hash_field:-}" ]]; then
	err_print "双击亮屏 bridge 输入哈希文件无效：$bridge_input_stamp"
	exit 1
fi
current_hash="$(calculate_bridge_input_hash)"
if [[ "$recorded_hash" != "$current_hash" ]]; then
	err_print "双击亮屏 bridge 预编译文件已落后于当前源码"
	err_print "请先执行：$bridge_build_script"
	exit 1
fi
if ! file "$bridge_prebuilt" | grep -Fq 'ELF 64-bit LSB pie executable, ARM aarch64'; then
	err_print "双击亮屏 bridge 不是 arm64 PIE：$bridge_prebuilt"
	exit 1
fi
if ! bridge_dynamic_section="$(LC_ALL=C readelf -dW "$bridge_prebuilt")"; then
	err_print "无法读取双击亮屏 bridge 动态段"
	exit 1
fi
mapfile -t bridge_needed_libraries < <(
	awk '
		index($0, "NEEDED") {
			left = index($0, "[")
			right = index($0, "]")
			if (left > 0 && right > left + 1) {
				print substr($0, left + 1, right - left - 1)
			}
		}
	' <<< "$bridge_dynamic_section"
)
bridge_has_needed_library() {
	local expected_library="${1:-}"
	local needed_library
	for needed_library in "${bridge_needed_libraries[@]}"; do
		if [[ "$needed_library" == "$expected_library" ]]; then
			return 0
		fi
	done
	return 1
}
missing_bridge_libraries=()
for required_library in libbinder_ndk.so liblog.so; do
	if ! bridge_has_needed_library "$required_library"; then
		missing_bridge_libraries+=("$required_library")
	fi
done
if (( ${#missing_bridge_libraries[@]} > 0 )); then
	err_print "双击亮屏 bridge 缺少预期动态依赖：${missing_bridge_libraries[*]}"
	exit 1
fi
if bridge_has_needed_library libc++.so; then
	err_print "双击亮屏 bridge 不应依赖目标平台 libc++ ABI"
	exit 1
fi
if readelf -lW "$bridge_prebuilt" | awk '$1 == "LOAD" && $NF != "0x4000" { invalid=1 } END { exit invalid ? 0 : 1 }'; then
	err_print "双击亮屏 bridge LOAD 段不是 16K 对齐"
	exit 1
fi

if ! grep -Fqx \
	'    interface aidl vendor.oplus.hardware.touch.IOplusTouch/default' \
	"$oplus_touch_rc" || \
	! grep -Fq '<name>vendor.oplus.hardware.touch</name>' "$oplus_touch_manifest" || \
	! grep -Fq '<fqname>IOplusTouch/default</fqname>' "$oplus_touch_manifest"; then
	err_print "底包没有已支持的 Oplus Touch AIDL V2 HBP 服务契约"
	exit 1
fi
if ! awk '
	$1 == "vendor.oplus.hardware.touch.IOplusTouch/default" &&
	$2 == "u:object_r:hal_oplus_touch_aidl_service:s0" &&
	NF == 2 { found = 1 }
	END { exit !found }
' "$vendor_service_contexts"; then
	err_print "底包缺少 IOplusTouch 精确 service_context"
	exit 1
fi
for expected_policy_line in \
	'(typeattribute hal_oplus_touch_aidl_client)' \
	'(typeattributeset hal_oplus_touch_aidl_server (hal_oplus_touch_aidl_default))' \
	'(allow hal_oplus_touch_aidl_client hal_oplus_touch_aidl_service (service_manager (find)))' \
	'(allow hal_oplus_touch_aidl_client hal_oplus_touch_aidl_server (binder (call transfer)))'; do
	if ! grep -Fqx "$expected_policy_line" "$vendor_plat_policy" && \
		! grep -Fqx "$expected_policy_line" "$vendor_policy"; then
		err_print "底包策略缺少 IOplusTouch 客户端契约：$expected_policy_line"
		exit 1
	fi
done
if ! awk '
	$1 == "/(odm|vendor/odm|vendor|system/vendor)/usr/keylayout(/.*)?\\.kl" &&
	$2 == "u:object_r:vendor_keylayout_file:s0" &&
	NF == 2 { found = 1 }
	END { exit !found }
' "$precompiled_file_contexts"; then
	err_print "底包 precompiled_file_contexts 缺少 ODM keylayout 通用标签"
	exit 1
fi

load_selinux_bundle_manifest "$bundle_manifest" "$patcher_dir"
for bundle_context_target in "${SELINUX_BUNDLE_CONTEXT_TARGETS[@]}"; do
	case "$bundle_context_target" in
		vendor_file_contexts|precompiled_file_contexts|odm_metadata_contexts|vendor_property_contexts|precompiled_property_contexts|vendor_service_contexts|precompiled_service_contexts)
			;;
		*)
			err_print "双击亮屏 SELinux bundle 使用了不受支持的目标：$bundle_context_target"
			exit 1
			;;
	esac
done
# The template placeholders are intentionally checked before expansion.
# shellcheck disable=SC2016
for expected_fragment_line in \
	'(type hal_touchfeature_oplus_bridge)' \
	'(type hal_touchfeature_oplus_bridge_exec)' \
	'(type hal_touchfeature_oplus_bridge_service)' \
	'(type vendor_touchfeature_compat_prop)' \
	'(typeattributeset hal_oplus_touch_aidl_client (hal_touchfeature_oplus_bridge))' \
	'(typetransition init_${API_VERSION} hal_touchfeature_oplus_bridge_exec process hal_touchfeature_oplus_bridge)' \
	'(allow system_server_${API_VERSION} hal_touchfeature_oplus_bridge (binder (call)))' \
	'(allow system_app_${API_VERSION} hal_touchfeature_oplus_bridge (binder (call)))'; do
	if ! grep -Fqx "$expected_fragment_line" "$bundle_policy"; then
		err_print "双击亮屏 SELinux 片段缺少契约：$expected_fragment_line"
		exit 1
	fi
done
if grep -Eq '/dev/(hbp|tp)|proc_touchpanel|sysfs_touch' "$bundle_policy"; then
	err_print "双击亮屏 bridge 策略不能绕过 IOplusTouch 直接访问触控节点"
	exit 1
fi
if ! grep -Fqx \
	'ro.vendor.touchfeature.type u:object_r:vendor_touchfeature_compat_prop:s0' \
	"$bundle_property_contexts" || \
	! grep -Fqx \
	'vendor.xiaomi.hw.touchfeature.ITouchFeature/default u:object_r:hal_touchfeature_oplus_bridge_service:s0' \
	"$bundle_service_contexts"; then
	err_print "双击亮屏 bundle 的 property/service context 契约不完整"
	exit 1
fi
if ! grep -Fq '<name>vendor.xiaomi.hw.touchfeature</name>' "$vintf_source" || \
	! grep -Fq '<fqname>ITouchFeature/default</fqname>' "$vintf_source" || \
	! grep -Fq 'interface aidl vendor.xiaomi.hw.touchfeature.ITouchFeature/default' "$rc_template"; then
	err_print "双击亮屏 Xiaomi TouchFeature RC/VINTF 契约不完整"
	exit 1
fi

binary_target="$project_dir/odm/bin/hw/vendor.dna.hardware.touchfeature-oplus-bridge"
rc_target="$project_dir/odm/etc/init/vendor.dna.hardware.touchfeature-oplus-bridge.rc"
vintf_target="$project_dir/odm/etc/vintf/manifest/vendor.dna.hardware.touchfeature-oplus-bridge.xml"
keylayout_target="$project_dir/odm/usr/keylayout/$input_device_name.kl"
for target_path in "$binary_target" "$rc_target" "$vintf_target" "$keylayout_target"; do
	if [[ -L "$target_path" || -d "$target_path" ]]; then
		err_print "双击亮屏目标路径类型不安全：$target_path"
		exit 1
	fi
	resolved_parent="$(realpath -m -- "$(dirname -- "$target_path")")"
	case "$resolved_parent" in
		"$project_dir/odm"|"$project_dir/odm"/*) ;;
		*)
			err_print "双击亮屏目标父目录越出 ODM：$target_path"
			exit 1
			;;
	esac
done

temporary_files=()
cleanup() {
	local temporary_file
	for temporary_file in "${temporary_files[@]}"; do
		rm -f -- "$temporary_file"
	done
}
trap cleanup EXIT

generated_rc="$(mktemp "$(get_config_path '.fix_oplus_double_tap_rc.XXXXXX')")"
generated_keylayout="$(mktemp "$(get_config_path '.fix_oplus_double_tap_keylayout.XXXXXX')")"
generated_prop="$(mktemp "$(get_config_path '.fix_oplus_double_tap_prop.XXXXXX')")"
generated_contexts_patch="$(mktemp "$(get_config_path '.fix_oplus_double_tap_contexts.XXXXXX')")"
generated_fsconfig_patch="$(mktemp "$(get_config_path '.fix_oplus_double_tap_fsconfig.XXXXXX')")"
temporary_odm_contexts="$(mktemp "$(get_config_path '.fix_oplus_double_tap_odm_contexts.XXXXXX')")"
temporary_odm_fsconfig="$(mktemp "$(get_config_path '.fix_oplus_double_tap_odm_fsconfig.XXXXXX')")"
temporary_files+=(
	"$generated_rc"
	"$generated_keylayout"
	"$generated_prop"
	"$generated_contexts_patch"
	"$generated_fsconfig_patch"
	"$temporary_odm_contexts"
	"$temporary_odm_fsconfig"
)

sed \
	-e "s/@PANEL_ID@/$panel_id/g" \
	-e "s/@GESTURE_CFG_NODE@/$gesture_cfg_node/g" \
	-e "s/@GESTURE_ENABLE_NODE@/$gesture_enable_node/g" \
	-e "s/@GESTURE_CFG_VALUE@/$gesture_cfg_value/g" \
	"$rc_template" > "$generated_rc"
sed -e "s/@SCAN_CODE@/$scan_code/g" "$keylayout_template" > "$generated_keylayout"
printf 'ro.vendor.touchfeature.type=%s\n' "$touchfeature_type" > "$generated_prop"
if grep -Eq '@[A-Z0-9_]+@' "$generated_rc" "$generated_keylayout"; then
	err_print "双击亮屏模板展开后仍含未解析占位符"
	exit 1
fi
if ! grep -Fqx "key $scan_code F4 WAKE" "$generated_keylayout"; then
	err_print "生成的 keylayout 缺少精确 WAKE 映射"
	exit 1
fi

escaped_input_device_name="${input_device_name//./\\.}"
cat > "$generated_contexts_patch" <<EOF
/odm/usr u:object_r:vendor_file:s0
/odm/usr/keylayout u:object_r:vendor_keylayout_file:s0
/odm/usr/keylayout/${escaped_input_device_name}\\.kl u:object_r:vendor_keylayout_file:s0
/odm/etc/init/vendor\\.dna\\.hardware\\.touchfeature-oplus-bridge\\.rc u:object_r:vendor_configs_file:s0
/odm/etc/vintf/manifest/vendor\\.dna\\.hardware\\.touchfeature-oplus-bridge\\.xml u:object_r:vendor_configs_file:s0
EOF
cat > "$generated_fsconfig_patch" <<EOF
odm/usr 0 0 0755
odm/usr/keylayout 0 0 0755
odm/usr/keylayout/${input_device_name}.kl 0 0 0644
odm/bin/hw/vendor.dna.hardware.touchfeature-oplus-bridge 0 2000 0755
odm/etc/init/vendor.dna.hardware.touchfeature-oplus-bridge.rc 0 0 0644
odm/etc/vintf/manifest/vendor.dna.hardware.touchfeature-oplus-bridge.xml 0 0 0644
EOF

cp -p -- "$odm_contexts" "$temporary_odm_contexts"
cp -p -- "$odm_fsconfig" "$temporary_odm_fsconfig"
merge_contexts_file "$bundle_odm_contexts" "$temporary_odm_contexts"
merge_contexts_file "$generated_contexts_patch" "$temporary_odm_contexts"
merge_fsconfig_file "$generated_fsconfig_patch" "$temporary_odm_fsconfig"

# All inputs and generated metadata have been validated.  Start modifying the
# target tree only after this point.
replace_file_if_different "$bridge_prebuilt" "$binary_target"
replace_file_if_different "$generated_rc" "$rc_target"
replace_file_if_different "$vintf_source" "$vintf_target"
replace_file_if_different "$generated_keylayout" "$keylayout_target"
chmod 0755 -- "$binary_target"
chmod 0644 -- "$rc_target" "$vintf_target" "$keylayout_target"
merge_prop_file "$generated_prop" "$odm_build_prop"
_install_generated_file "$temporary_odm_contexts" "$odm_contexts"
_install_generated_file "$temporary_odm_fsconfig" "$odm_fsconfig"

check_selinux_bundle_requirements "$project_dir"
if [[ "$SELINUX_BUNDLE_ACTIVE" != true ]]; then
	err_print "双击亮屏 bridge 安装后仍未形成完整 SELinux bundle requirement"
	exit 1
fi

std_print "✅ 已安装 Xiaomi TouchFeature -> Oplus IOplusTouch AIDL bridge"
std_print "✅ 已写入 $input_device_name.kl：scan code $scan_code -> F4 WAKE"
std_print "✅ 已设置 ro.vendor.touchfeature.type=$touchfeature_type 并补齐 ODM metadata"
std_print "✅ 双击亮屏 SELinux 策略与 contexts 已登记到 feature bundle"
std_print "ℹ️ 由 common/fix_vendor_avc 统一合并 normal/debug CIL 与早期 contexts"
std_print "处理完成"
