#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "适配 NXP NFC 系统应用、属性与 SELinux 服务契约"
std_print "来源：补丁内置 NXP/Xiaomi NFC APK、目标设备流程显式配置；目标：原包 system、底包 odm"
std_print

for part_name in odm vendor system system_ext; do
	check_part_exists "$part_name"
done

# project_dir 由 tools.sh 的 init_port_env 设置。
source_file="${NFC_PROPERTIES_FILE:-}"
# shellcheck disable=SC2154
target_file="$project_dir/odm/etc/build.prop"
prop_list="$patcher_dir/config/target_props.list"
nfc_apk_source="$patcher_dir/prebuilt/XMNfcNci.apk"
nfc_apk_checksums="$patcher_dir/config/XMNfcNci.apk.sha256"
nfc_apk_validator="$patcher_dir/validate_nfc_apk.py"
nfc_apk_target="$project_dir/system/system/app/Nfc_st/Nfc_st.apk"
nxp_hal="$project_dir/odm/bin/hw/android.hardware.nfc-service.nxp"
nxp_hal_rc="$project_dir/odm/etc/init/nfc-service-nxp.rc"
nxp_manifest="$project_dir/odm/etc/vintf/manifest/nfc-service.xml"
selinux_bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
selinux_policy_fragment="$patcher_dir/config/selinux_policy.cil.in"
vendor_selinux="$project_dir/vendor/etc/selinux"
vendor_policy="$vendor_selinux/vendor_sepolicy.cil"
vendor_versioned_policy="$vendor_selinux/plat_pub_versioned.cil"
vendor_debug_policy="$vendor_selinux/vendor_sepolicy_debug.cil"
vendor_debug_versioned_policy="$vendor_selinux/plat_pub_versioned_debug.cil"
vendor_policy_version="$vendor_selinux/plat_sepolicy_vers.txt"
vendor_file_contexts="$vendor_selinux/vendor_file_contexts"
precompiled_file_contexts="$project_dir/odm/etc/selinux/precompiled_file_contexts"
vendor_property_contexts="$vendor_selinux/vendor_property_contexts"
precompiled_property_contexts="$project_dir/odm/etc/selinux/precompiled_property_contexts"
vendor_service_contexts="$vendor_selinux/vendor_service_contexts"
precompiled_service_contexts="$project_dir/odm/etc/selinux/precompiled_service_contexts"
required_nfc_frameworks=(
	"$project_dir/system_ext/framework/com.nxp.nfc.jar"
	"$project_dir/system_ext/framework/com.nxp.nfc.nq.jar"
	"$project_dir/system_ext/framework/com.xiaomi.nfc.jar"
)

for required_file in \
	"$nxp_hal" \
	"$nxp_hal_rc" \
	"$nxp_manifest" \
	"$selinux_bundle_manifest" \
	"$selinux_policy_fragment" \
	"$vendor_policy" \
	"$vendor_versioned_policy" \
	"$vendor_policy_version" \
	"$vendor_file_contexts" \
	"$precompiled_file_contexts" \
	"$vendor_property_contexts" \
	"$precompiled_property_contexts" \
	"$vendor_service_contexts" \
	"$precompiled_service_contexts"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "NFC 服务或 SELinux 契约输入不能是符号链接：$required_file"
		exit 1
	fi
done

load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"
expected_bundle_requirements=(
	odm/bin/hw/android.hardware.nfc-service.nxp
	odm/etc/init/nfc-service-nxp.rc
	odm/etc/vintf/manifest/nfc-service.xml
)
if (( ${#SELINUX_BUNDLE_REQUIREMENTS[@]} != ${#expected_bundle_requirements[@]} ||
	${#SELINUX_BUNDLE_POLICY_FRAGMENTS[@]} != 1 ||
	${#SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]} != 4 )); then
	err_print "NFC SELinux bundle 的 requirement/policy 结构不完整"
	exit 1
fi
for requirement_index in "${!expected_bundle_requirements[@]}"; do
	if [[ "${SELINUX_BUNDLE_REQUIREMENTS[$requirement_index]}" != \
		"${expected_bundle_requirements[$requirement_index]}" ]]; then
		err_print "NFC SELinux bundle requirement 与服务契约不一致"
		exit 1
	fi
done
expected_service_fragment="$(realpath -e -- "$patcher_dir/config/nfc_service_contexts")"
for service_context_target in vendor_service_contexts precompiled_service_contexts; do
	service_context_found=0
	for context_index in "${!SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]}"; do
		if [[ "${SELINUX_BUNDLE_CONTEXT_TARGETS[$context_index]}" == "$service_context_target" &&
			"${SELINUX_BUNDLE_CONTEXT_FRAGMENTS[$context_index]}" == "$expected_service_fragment" ]]; then
			((service_context_found += 1))
		fi
	done
	if (( service_context_found != 1 )); then
		err_print "NFC SELinux bundle 缺少 $service_context_target service contexts 片段"
		exit 1
	fi
done
if [[ "${SELINUX_BUNDLE_POLICY_FRAGMENTS[0]}" != \
	"$(realpath -e -- "$selinux_policy_fragment")" ]]; then
	err_print "NFC SELinux bundle 没有引用模块自有策略片段"
	exit 1
fi
expected_property_fragment="$(realpath -e -- "$patcher_dir/config/nfc_property_contexts")"
for property_context_target in vendor_property_contexts precompiled_property_contexts; do
	property_context_found=0
	for context_index in "${!SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]}"; do
		if [[ "${SELINUX_BUNDLE_CONTEXT_TARGETS[$context_index]}" == "$property_context_target" &&
			"${SELINUX_BUNDLE_CONTEXT_FRAGMENTS[$context_index]}" == "$expected_property_fragment" ]]; then
			((property_context_found += 1))
		fi
	done
	if (( property_context_found != 1 )); then
		err_print "NFC SELinux bundle 缺少 $property_context_target property contexts 片段"
		exit 1
	fi
done

api_version="$(tr -d '[:space:]' < "$vendor_policy_version")"
if [[ ! "$api_version" =~ ^[0-9]+$ ]]; then
	err_print "NFC SELinux bundle 无法识别目标 policy API：$api_version"
	exit 1
fi
# shellcheck disable=SC2016 # API_VERSION 由 common/selinux_merge 在落盘前展开。
expected_nfc_rule='(allow system_server_${API_VERSION} hal_nfc_default (process (signal)))'
# shellcheck disable=SC2016 # Array entries preserve API_VERSION for the merger.
expected_nfc_policy_statements=(
	"$expected_nfc_rule"
	'(type vendor_nfc_mi_prop)'
	'(roletype object_r vendor_nfc_mi_prop)'
	'(typeattributeset property_type (vendor_nfc_mi_prop))'
	'(typeattributeset vendor_property_type (vendor_nfc_mi_prop))'
	'(typeattributeset vendor_public_property_type (vendor_nfc_mi_prop))'
	'(allow hal_nfc_default vendor_nfc_mi_prop (property_service (set)))'
	'(allow hal_nfc_default vendor_nfc_mi_prop (file (read getattr map open)))'
	'(allow hal_nfc_default property_socket_${API_VERSION} (sock_file (write)))'
	'(allow hal_nfc_default init_${API_VERSION} (unix_stream_socket (connectto)))'
	'(allow hal_secure_element_default vendor_nfc_mi_prop (property_service (set)))'
	'(allow hal_secure_element_default vendor_nfc_mi_prop (file (read getattr map open)))'
	'(allow nfc_${API_VERSION} vendor_nfc_mi_prop (file (read getattr map open)))'
	'(allow secure_element_${API_VERSION} vendor_nfc_mi_prop (file (read getattr map open)))'
	'(allow system_app_${API_VERSION} vendor_nfc_mi_prop (file (read getattr map open)))'
	'(allow vendor_init_${API_VERSION} vendor_nfc_mi_prop (property_service (set)))'
	'(allow vendor_init_${API_VERSION} vendor_nfc_mi_prop (file (read getattr map open)))'
)
for expected_statement in "${expected_nfc_policy_statements[@]}"; do
	if ! grep -Fqx "$expected_statement" "$selinux_policy_fragment"; then
		err_print "NFC SELinux 片段缺少预期策略条目：$expected_statement"
		exit 1
	fi
done
if (( $(grep -Ec '^[[:space:]]*\(' "$selinux_policy_fragment") != ${#expected_nfc_policy_statements[@]} )); then
	err_print "NFC SELinux 片段包含未声明的额外策略条目"
	exit 1
fi
if ! grep -Fqx 'ro.vendor.nfc. u:object_r:vendor_nfc_mi_prop:s0' "$patcher_dir/config/nfc_property_contexts" ||
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$patcher_dir/config/nfc_property_contexts") != 1 )); then
	err_print "NFC property contexts 片段必须只声明 ro.vendor.nfc."
	exit 1
fi
if ! grep -Fqx 'mi_nfc u:object_r:nfc_service:s0' "$patcher_dir/config/nfc_service_contexts" ||
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$patcher_dir/config/nfc_service_contexts") != 1 )); then
	err_print "NFC service contexts 片段必须只声明 mi_nfc"
	exit 1
fi
validate_nfc_policy_contract() {
	local policy_file="${1:-}"
	local versioned_policy_file="${2:-}"
	local policy_label="${3:-vendor}"

	if ! grep -Fqx '(type hal_nfc_default)' "$policy_file" ||
		! grep -Fqx '(type hal_nfc_default_exec)' "$policy_file" ||
		! grep -Fqx \
			"(typetransition init_${api_version} hal_nfc_default_exec process hal_nfc_default)" \
			"$policy_file" ||
		! grep -Eq \
			"(^|[^A-Za-z0-9_])system_server_${api_version}([^A-Za-z0-9_]|$)" \
			"$versioned_policy_file"; then
		err_print "$policy_label policy 缺少 NXP NFC 域转换或版本化 system_server 类型"
		return 1
	fi
}

validate_nfc_policy_contract "$vendor_policy" "$vendor_versioned_policy" "底包 normal"
if [[ -e "$vendor_debug_policy" || -L "$vendor_debug_policy" ||
	-e "$vendor_debug_versioned_policy" || -L "$vendor_debug_versioned_policy" ]]; then
	for debug_policy_file in "$vendor_debug_policy" "$vendor_debug_versioned_policy"; do
		check_file_exists "$debug_policy_file"
		if [[ -L "$debug_policy_file" ]]; then
			err_print "NFC debug SELinux 契约输入不能是符号链接：$debug_policy_file"
			exit 1
		fi
	done
	validate_nfc_policy_contract \
		"$vendor_debug_policy" \
		"$vendor_debug_versioned_policy" \
		"底包 debug"
fi
if ! grep -Fqx \
	'service vendor.nfc_hal_service /odm/bin/hw/android.hardware.nfc-service.nxp' \
	"$nxp_hal_rc" ||
	! grep -Fq '<name>vendor.nxp.nxpnfc_aidl</name>' "$nxp_manifest"; then
	err_print "底包 NXP NFC RC/VINTF 服务契约不完整"
	exit 1
fi
expected_exec_context='/(odm|vendor)/bin/hw/android\.hardware\.nfc-service\.nxp u:object_r:hal_nfc_default_exec:s0'
for runtime_contexts in "$vendor_file_contexts" "$precompiled_file_contexts"; do
	if ! grep -Fqx "$expected_exec_context" "$runtime_contexts"; then
		err_print "底包缺少 NXP NFC executable 标签：$runtime_contexts"
		exit 1
	fi
done
check_selinux_bundle_requirements "$project_dir"
if [[ "$SELINUX_BUNDLE_ACTIVE" != true ]]; then
	err_print "NXP NFC 服务未形成完整 SELinux bundle requirement"
	exit 1
fi

apk_update_ready=1
replace_nfc_apk=0
if [[ -L "$nfc_apk_target" ]]; then
	err_print "不支持替换符号链接 NFC APK：$nfc_apk_target"
	exit 1
elif [[ ! -e "$nfc_apk_target" ]]; then
	warn_print "待替换的 NFC APK 不存在，跳过 APK 子步骤：${nfc_apk_target#"$project_dir"/}"
	apk_update_ready=0
elif [[ ! -f "$nfc_apk_target" ]]; then
	err_print "待替换的 NFC APK 不是普通文件：$nfc_apk_target"
	exit 1
fi

if (( apk_update_ready == 1 )); then
	check_file_exists "$nfc_apk_source"
	check_file_exists "$nfc_apk_checksums"
	check_file_exists "$nfc_apk_validator"
	for framework_file in "${required_nfc_frameworks[@]}"; do
		check_file_exists "$framework_file"
	done
	if [[ -L "$nfc_apk_source" ]]; then
		err_print "NFC APK 源文件必须是普通文件：$nfc_apk_source"
		exit 1
	fi
	if [[ -L "$nfc_apk_checksums" ]]; then
		err_print "NFC APK 校验清单必须是普通文件：$nfc_apk_checksums"
		exit 1
	fi
	if ! command -v sha256sum >/dev/null 2>&1; then
		err_print "缺少 sha256sum，无法校验项目内置 NFC APK"
		exit 1
	fi
	if ! (cd -- "$patcher_dir" && sha256sum -c -- "$nfc_apk_checksums"); then
		err_print "内置 XMNfcNci.apk 校验失败"
		exit 1
	fi
	if ! PYTHONDONTWRITEBYTECODE=1 python3 "$nfc_apk_validator" \
		--reference "$nfc_apk_source" "$nfc_apk_target"; then
		err_print "Nfc_st.apk 未通过跨 OTA 的 NFC APK 结构契约，拒绝覆盖"
		exit 1
	fi
	if cmp -s -- "$nfc_apk_source" "$nfc_apk_target"; then
		replace_nfc_apk=0
	else
		replace_nfc_apk=1
	fi
fi

prop_patch=""
cleanup() {
	if [[ -n "$prop_patch" ]]; then
		rm -f -- "$prop_patch"
	fi
}
trap cleanup EXIT

prop_count=0
prop_update_ready=1
if [[ -z "$source_file" ]]; then
	warn_print "未提供目标设备 NFC 属性配置（NFC_PROPERTIES_FILE），跳过属性写入"
	prop_update_ready=0
elif [[ -L "$source_file" ]]; then
	err_print "目标设备 NFC 属性配置不能是符号链接：$source_file"
	exit 1
elif [[ ! -e "$source_file" ]]; then
	warn_print "目标设备 NFC 属性配置不存在，跳过属性写入：$source_file"
	prop_update_ready=0
elif [[ ! -f "$source_file" ]]; then
	err_print "目标设备 NFC 属性配置不是普通文件：$source_file"
	exit 1
fi
if (( prop_update_ready == 1 )); then
	validate_prop_file "$source_file"
fi
if [[ -L "$target_file" ]]; then
	err_print "不支持直接修改符号链接：$target_file"
	exit 1
elif [[ ! -e "$target_file" ]]; then
	warn_print "NFC 属性目标不存在，跳过属性写入：${target_file#"$project_dir"/}"
	prop_update_ready=0
elif [[ ! -f "$target_file" ]]; then
	err_print "NFC 属性目标不是普通文件：$target_file"
	exit 1
fi
if [[ -L "$prop_list" ]]; then
	err_print "NFC 属性清单不能是符号链接：$prop_list"
	exit 1
elif [[ ! -e "$prop_list" ]]; then
	warn_print "NFC 属性清单不存在，跳过属性写入：${prop_list#"$port_dir"/}"
	prop_update_ready=0
elif [[ ! -f "$prop_list" ]]; then
	err_print "NFC 属性清单不是普通文件：$prop_list"
	exit 1
fi
if (( prop_update_ready == 1 )); then
	prop_patch="$(mktemp "$(get_config_path '.fix_nfc.XXXXXX')")"
	declare -A seen_keys=()
	listed_prop_count=0
	while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
		raw_line="${raw_line%$'\r'}"
		prop_key="${raw_line#"${raw_line%%[![:space:]]*}"}"
		prop_key="${prop_key%"${prop_key##*[![:space:]]}"}"
		[[ -z "$prop_key" || "$prop_key" == \#* ]] && continue
		((listed_prop_count += 1))
		if [[ ! "$prop_key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
			err_print "属性清单存在无效属性名：$prop_list：$prop_key"
			exit 1
		fi
		if [[ -n "${seen_keys[$prop_key]:-}" ]]; then
			err_print "属性清单存在重复属性：$prop_list：$prop_key"
			exit 1
		fi
		seen_keys["$prop_key"]=1
		if ! grep -Eq "^[[:space:]]*${prop_key//./\\.}[[:space:]]*=" "$source_file"; then
			warn_print "目标设备 NFC 配置缺少属性，跳过：$prop_key"
			continue
		fi
		prop_value="$(read_prop_value "$prop_key" "$source_file")"
		if [[ -z "$prop_value" ]]; then
			warn_print "目标设备 NFC 属性值为空，跳过：$prop_key"
			continue
		fi
		printf '%s=%s\n' "$prop_key" "$prop_value" >> "$prop_patch"
		((prop_count += 1))
	done < "$prop_list"

	if (( listed_prop_count == 0 )); then
		warn_print "NFC 属性清单没有有效条目，跳过属性写入：${prop_list#"$port_dir"/}"
		prop_update_ready=0
	elif (( prop_count == 0 )); then
		warn_print "目标设备配置中没有可写入的 NFC 属性，跳过属性写入"
		prop_update_ready=0
	else
		validate_prop_file "$prop_patch"
	fi
fi

if (( prop_update_ready == 1 )); then
	merge_prop_file "$prop_patch" "$target_file"
	std_print "✅ 已从目标设备配置写入 $prop_count 项 NFC 属性：${target_file#"$project_dir"/}"
fi

if (( apk_update_ready == 0 )); then
	:
elif (( replace_nfc_apk == 1 )); then
	replace_file_if_different "$nfc_apk_source" "$nfc_apk_target"
	if ! cmp -s -- "$nfc_apk_source" "$nfc_apk_target"; then
		err_print "NFC APK 替换后内容校验失败：$nfc_apk_target"
		exit 1
	fi
	std_print "✅ 已用 NXP/Xiaomi NFC 系统应用替换 system/system/app/Nfc_st/Nfc_st.apk"
else
	skip_print "Nfc_st.apk 已是目标 NXP/Xiaomi 版本"
fi

std_print "✅ 已登记 NXP NFC 最小 SELinux bundle，交由 common/fix_vendor_avc 统一合并"
std_print "处理完成"
