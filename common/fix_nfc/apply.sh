#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "替换 ST NFC 系统应用并补充 Xiaomi NFC 功能属性"
std_print "来源：补丁内置 NXP/Xiaomi NFC APK、小米原包 mi_odm；目标：原包 system、底包 odm"
std_print

for part_name in mi_odm odm system system_ext; do
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

check_file_exists "$source_file"
check_file_exists "$target_file"
check_file_exists "$prop_list"
check_file_exists "$nfc_apk_source"
check_file_exists "$nfc_apk_checksums"
check_file_exists "$nfc_apk_target"
check_file_exists "$nxp_hal"
check_file_exists "$nxp_manifest"
for framework_file in "${required_nfc_frameworks[@]}"; do
	check_file_exists "$framework_file"
done

if [[ -L "$target_file" ]]; then
	err_print "不支持直接修改符号链接：$target_file"
	exit 1
fi
if [[ -L "$nfc_apk_source" || -L "$nfc_apk_target" ]]; then
	err_print "NFC APK 源文件和目标文件都必须是普通文件"
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

prop_patch="$(mktemp "$(get_config_path '.fix_nfc.XXXXXX')")"
cleanup() {
	rm -f -- "$prop_patch"
}
trap cleanup EXIT

declare -A seen_keys=()
prop_count=0
while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
	raw_line="${raw_line%$'\r'}"
	prop_key="${raw_line#"${raw_line%%[![:space:]]*}"}"
	prop_key="${prop_key%"${prop_key##*[![:space:]]}"}"
	[[ -z "$prop_key" || "$prop_key" == \#* ]] && continue
	if [[ ! "$prop_key" =~ ^[A-Za-z0-9_.-]+$ ]]; then
		err_print "属性清单存在无效属性名：$prop_list：$prop_key"
		exit 1
	fi
	if [[ -n "${seen_keys[$prop_key]:-}" ]]; then
		err_print "属性清单存在重复属性：$prop_list：$prop_key"
		exit 1
	fi
	seen_keys["$prop_key"]=1
	prop_value="$(read_prop_value "$prop_key" "$source_file")"
	if [[ -z "$prop_value" ]]; then
		err_print "mi_odm 属性值不能为空：$prop_key"
		exit 1
	fi
	printf '%s=%s\n' "$prop_key" "$prop_value" >> "$prop_patch"
	((prop_count += 1))
done < "$prop_list"

if (( prop_count == 0 )); then
	err_print "属性清单没有有效属性：$prop_list"
	exit 1
fi

validate_prop_file "$prop_patch"
merge_prop_file "$prop_patch" "$target_file"
std_print "✅ 已从 mi_odm 动态提取并写入 $prop_count 项 NFC 属性：${target_file#"$project_dir"/}"

if (( replace_nfc_apk == 1 )); then
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
