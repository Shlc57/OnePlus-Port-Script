#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "替换 ST NFC 系统应用并补充 Xiaomi NFC 功能属性"
std_print "来源：补丁内置 NXP/Xiaomi NFC APK、小米原包 mi_odm；目标：原包 system、底包 odm"
std_print

for part_name in odm system system_ext; do
	check_part_exists "$part_name"
done

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
source_file="$project_dir/mi_odm/etc/build.prop"
target_file="$project_dir/odm/etc/build.prop"
prop_list="$patcher_dir/config/mi_odm_props.list"
nfc_apk_source="$patcher_dir/prebuilt/XMNfcNci.apk"
nfc_apk_checksums="$patcher_dir/config/XMNfcNci.apk.sha256"
nfc_apk_target="$project_dir/system/system/app/Nfc_st/Nfc_st.apk"
expected_st_apk_sha256="ad9bf76f39243ef776a24604e5206606e314c69dda3d9f0d8de0cafcebe6aa53"
nxp_hal="$project_dir/odm/bin/hw/android.hardware.nfc-service.nxp"
nxp_manifest="$project_dir/odm/etc/vintf/manifest/nfc-service.xml"
required_nfc_frameworks=(
	"$project_dir/system_ext/framework/com.nxp.nfc.jar"
	"$project_dir/system_ext/framework/com.nxp.nfc.nq.jar"
	"$project_dir/system_ext/framework/com.xiaomi.nfc.jar"
)

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
	check_file_exists "$nxp_hal"
	check_file_exists "$nxp_manifest"
	for framework_file in "${required_nfc_frameworks[@]}"; do
		check_file_exists "$framework_file"
	done
	if [[ -L "$nfc_apk_source" ]]; then
		err_print "NFC APK 源文件必须是普通文件：$nfc_apk_source"
		exit 1
	fi
	if ! command -v sha256sum >/dev/null 2>&1; then
		err_print "缺少 sha256sum，无法校验 NFC APK"
		exit 1
	fi
	if ! (cd -- "$patcher_dir" && sha256sum -c -- "$nfc_apk_checksums"); then
		err_print "内置 XMNfcNci.apk 校验失败"
		exit 1
	fi
	if ! grep -Fq '<name>vendor.nxp.nxpnfc_aidl</name>' "$nxp_manifest"; then
		err_print "底包 NFC manifest 不是已支持的 NXP AIDL 栈：$nxp_manifest"
		exit 1
	fi

	read -r nxp_apk_sha256 _ < <(sha256sum -- "$nfc_apk_source")
	read -r target_apk_sha256 _ < <(sha256sum -- "$nfc_apk_target")
	case "$target_apk_sha256" in
		"$expected_st_apk_sha256")
			replace_nfc_apk=1
			;;
		"$nxp_apk_sha256")
			replace_nfc_apk=0
			;;
		*)
			err_print "Nfc_st.apk 不属于当前支持版本，拒绝覆盖：$target_apk_sha256"
			exit 1
			;;
	esac
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
if [[ -L "$source_file" ]]; then
	err_print "不支持从符号链接读取属性：$source_file"
	exit 1
elif [[ ! -e "$source_file" ]]; then
	warn_print "NFC 属性来源不存在，跳过属性写入：${source_file#"$project_dir"/}"
	prop_update_ready=0
elif [[ ! -f "$source_file" ]]; then
	err_print "NFC 属性来源不是普通文件：$source_file"
	exit 1
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
			warn_print "NFC 来源属性不存在，跳过：$prop_key"
			continue
		fi
		prop_value="$(read_prop_value "$prop_key" "$source_file")"
		if [[ -z "$prop_value" ]]; then
			warn_print "NFC 来源属性值为空，跳过：$prop_key"
			continue
		fi
		printf '%s=%s\n' "$prop_key" "$prop_value" >> "$prop_patch"
		((prop_count += 1))
	done < "$prop_list"

	if (( listed_prop_count == 0 )); then
		warn_print "NFC 属性清单没有有效条目，跳过属性写入：${prop_list#"$port_dir"/}"
		prop_update_ready=0
	elif (( prop_count == 0 )); then
		warn_print "mi_odm 中没有可写入的 NFC 属性，跳过属性写入"
		prop_update_ready=0
	else
		validate_prop_file "$prop_patch"
	fi
fi

if (( prop_update_ready == 1 )); then
	merge_prop_file "$prop_patch" "$target_file"
	std_print "✅ 已从 mi_odm 动态提取并写入 $prop_count 项 NFC 属性：${target_file#"$project_dir"/}"
fi

if (( apk_update_ready == 0 )); then
	:
elif (( replace_nfc_apk == 1 )); then
	replace_file_if_different "$nfc_apk_source" "$nfc_apk_target"
	read -r installed_apk_sha256 _ < <(sha256sum -- "$nfc_apk_target")
	if [[ "$installed_apk_sha256" != "$nxp_apk_sha256" ]]; then
		err_print "NFC APK 替换后校验失败：$nfc_apk_target"
		exit 1
	fi
	std_print "✅ 已用 NXP/Xiaomi NFC 系统应用替换 system/system/app/Nfc_st/Nfc_st.apk"
else
	skip_print "Nfc_st.apk 已是目标 NXP/Xiaomi 版本"
fi

std_print "处理完成"
