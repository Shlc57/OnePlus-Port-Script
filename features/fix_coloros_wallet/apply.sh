#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "安装 ColorOS 钱包五件套（FinShellWallet/TasWallet/UPTsmService/HeytapHTMS/EidService）"
std_print "来源：模块 prebuilt（目标机型底包 system 提取产物）；目标：原包 system、system_ext"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154

# 钱包五件套清单：分区 运行时 contexts 路径。布局与 ColorOS 底包一致，五件套必须
# 整体安装，不允许部分安装造成 FinShell 与 TAS/HTMS/TSM 依赖断裂。
declare -a wallet_apps=(
	"system FinShellWallet"
	"system TasWallet"
	"system UPTsmService"
	"system HeytapHTMS"
	"system_ext EidService"
)

declare -a temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

check_partition_metadata_tool >/dev/null
for part_name in system system_ext odm; do
	check_part_exists "$part_name"
	check_file_exists "$(get_part_contexts_path "$part_name")"
	check_file_exists "$(get_part_fsconfig_path "$part_name")"
done

# 分区最终工作树根：system 分区文件树位于 system/system/...；system_ext 不嵌套。
# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
partition_worktree_root() {
	local part_name="${1:-}"
	case "$part_name" in
		system)
			printf '%s\n' "$project_dir/system/system"
			;;
		system_ext)
			printf '%s\n' "$project_dir/system_ext"
			;;
		*)
			err_print "钱包五件套不支持的目标分区：$part_name"
			return 1
			;;
	esac
}

prebuilt_root="$patcher_dir/prebuilt"
declare -a missing_apps=()
prepare_wallet_sources() {
	local app_entry part_name app_name
	local source_dir source_apk

	for app_entry in "${wallet_apps[@]}"; do
		read -r part_name app_name <<<"$app_entry"
		source_dir="$prebuilt_root/$part_name/app/$app_name"
		source_apk="$source_dir/$app_name.apk"

		if [[ ! -d "$source_dir" ]]; then
			missing_apps+=("$part_name/app/$app_name")
			continue
		fi
		if [[ -L "$source_apk" || ! -f "$source_apk" ]]; then
			missing_apps+=("$part_name/app/$app_name（缺少 $app_name.apk）")
			continue
		fi
		if [[ -n "$(find "$source_dir" -type l -print -quit)" ]]; then
			err_print "预置钱包来源不允许包含符号链接：${source_dir#"$patcher_dir"/}"
			return 1
		fi
	done
}

if [[ -e "$prebuilt_root" && ! -d "$prebuilt_root" ]]; then
	err_print "钱包预置来源不是普通目录：$prebuilt_root"
	exit 1
fi
prepare_wallet_sources
if [[ ! -d "$prebuilt_root" || ${#missing_apps[@]} -gt 0 ]]; then
	if [[ ! -d "$prebuilt_root" ]]; then
		warn_print "钱包预置来源目录不存在：${prebuilt_root#"$port_dir"/}"
	fi
	for missing_item in "${missing_apps[@]}"; do
		warn_print "钱包五件套预置产物缺失：prebuilt/$missing_item"
	done
	warn_print "请从目标机型底包 ROM 的 system.img 提取五件套后放入上述路径，" \
		"布局保持 app/<App>/<App>.apk 与 lib/arm64 原样"
	skip_print "钱包五件套未就绪，整体跳过安装"
	exit 0
fi

# 校验全部通过后才动工作树。copy_tree_missing_only 只补缺失文件，已存在且内容
# 相同则幂等跳过；目标冲突（内容不同/类型不符）视为错误。
for app_entry in "${wallet_apps[@]}"; do
	read -r part_name app_name <<<"$app_entry"
	worktree_root="$(partition_worktree_root "$part_name")"
	source_dir="$prebuilt_root/$part_name/app/$app_name"
	target_dir="$worktree_root/app/$app_name"
	copy_tree_missing_only "$source_dir" "$target_dir"
	std_print "✅ 钱包应用已就绪 $app_name（${part_name}）"
done

# 按复制后的目标树补齐 metadata。路径约定与原包一致：fsconfig 为项目目录相对全路径
# （system 分区为 system/system/app/...，system_ext 为 system_ext/app/...），
# contexts 为 "/" + 同一相对路径；fsconfig 目录 0755 / 文件 0644，无 capabilities 列。
append_tree_metadata() {
	local part_name="${1:-}"
	local fsconfig_patch contexts_patch
	local app_entry app_part_name app_name app_target app_contexts_root
	local source_path relative_path entry_mode

	fsconfig_patch="$(mktemp "$(get_config_path ".wallet_fsconfig.XXXXXX")")"
	temporary_files+=("$fsconfig_patch")
	contexts_patch="$(mktemp "$(get_config_path ".wallet_contexts.XXXXXX")")"
	temporary_files+=("$contexts_patch")

	for app_entry in "${wallet_apps[@]}"; do
		read -r app_part_name app_name <<<"$app_entry"
		[[ "$app_part_name" == "$part_name" ]] || continue
		app_target="$(partition_worktree_root "$part_name")/app/$app_name"
		app_contexts_root="/${app_target#"$project_dir"/}"
		printf '%s(/.*)? u:object_r:system_file:s0\n' "$app_contexts_root" \
			>> "$contexts_patch"
		while IFS= read -r -d '' source_path; do
			relative_path="${source_path#"$project_dir"/}"
			if [[ -d "$source_path" ]]; then
				entry_mode=0755
			else
				entry_mode=0644
			fi
			printf '%s 0 0 %s\n' "$relative_path" "$entry_mode" >> "$fsconfig_patch"
		done < <(find "$app_target" -mindepth 0 -print0)
	done

	merge_fsconfig_file "$fsconfig_patch" "$(get_part_fsconfig_path "$part_name")"
	merge_contexts_file "$contexts_patch" "$(get_part_contexts_path "$part_name")"
}

append_tree_metadata system
append_tree_metadata system_ext
std_print "✅ 钱包五件套 contexts 与 fsconfig 已合并"

# ── 钱包运行时依赖固化（无 LSP 路线）────────────────────────────────
# 1) 身份键 rc：原包 system build.prop 把 ro.product.brand/manufacturer 污染为
#    小米值，Build.BRAND 走 zygote 预加载缓存导致 FinShell 厂商门判定失败
#    （"不支持的厂商"弹窗）。odm/etc/init rc 在 post-fs-data（早于 zygote）由
#    init 直接 setprop，机制同 xiaoai_wakeup_props.rc；分区键 odm.brand=Xiaomi
#    保留给小米生态，仅覆盖运行时全局键。
# 2) OSense stub：FinShell 解冻 SDK 引用 com.oplus.osense.* 欧加框架类，移植
#    系统缺失导致 LongTimeUnfreezeManager NoClassDefFoundError 闪退。提供最小
#    空实现 jar 并注入 zygote BOOTCLASSPATH，行为等价参考 LSP 方案的
#    addDexPath + 强制空 fallback（EmptyLongUnfreezeManager 逻辑仍在 APK 内）。

wallet_props_rc_target="$project_dir/odm/etc/init/coloros_wallet_props.rc"
wallet_osense_jar_target="$project_dir/system/system/framework/oplus-osense-stub.jar"
wallet_zygote_rc_target="$project_dir/system/system/etc/init/hw/init.zygote64.rc"
wallet_bcp_file="$patcher_dir/config/zygote_bootclasspath.txt"

# 单行 metadata 补丁文件：mktemp + 临时清理，兼容 merge_*_file 的存在性校验。
append_wallet_metadata_patch() {
	local kind="${1:-}" line="${2:-}"
	local patch_file
	patch_file="$(mktemp "$(get_config_path ".wallet_${kind}.XXXXXX")")"
	temporary_files+=("$patch_file")
	printf '%s\n' "$line" > "$patch_file"
	case "$kind" in
		fsconfig)
			merge_fsconfig_file "$patch_file" "$(get_part_fsconfig_path odm)" ;;
		contexts)
			merge_contexts_file "$patch_file" "$(get_part_contexts_path odm)" ;;
		fsconfig_system)
			merge_fsconfig_file "$patch_file" "$(get_part_fsconfig_path system)" ;;
		contexts_system)
			merge_contexts_file "$patch_file" "$(get_part_contexts_path system)" ;;
		*)
			err_print "未知 metadata 类型：$kind"
			return 1
			;;
	esac
}

install_wallet_props_rc() {
	if [[ -L "$wallet_props_rc_target" ]]; then
		err_print "钱包身份键 rc 目标不能是符号链接：$wallet_props_rc_target"
		return 1
	fi
	if [[ -f "$wallet_props_rc_target" ]]; then
		if ! grep -q 'ColorOS 钱包运行时身份键' "$wallet_props_rc_target"; then
			err_print "钱包身份键 rc 目标已被无关内容占用：${wallet_props_rc_target#"$project_dir"/}"
			return 1
		fi
		skip_print "钱包身份键 rc 已存在，同步 metadata"
	else
		check_file_exists "$patcher_dir/prebuilt/odm_init/coloros_wallet_props.rc" || return 1
		mkdir -p -- "$project_dir/odm/etc/init"
		copy_file_missing_only "$patcher_dir/prebuilt/odm_init/coloros_wallet_props.rc" \
			"$wallet_props_rc_target"
		std_print "✅ 钱包身份键 rc 已写入 odm"
	fi
	append_wallet_metadata_patch fsconfig 'odm/etc/init/coloros_wallet_props.rc 0 0 0644'
	append_wallet_metadata_patch contexts '/odm/etc/init/coloros_wallet_props\.rc u:object_r:vendor_configs_file:s0'
}

install_osense_stub() {
	if [[ -L "$wallet_osense_jar_target" ]]; then
		err_print "OSense stub 目标不能是符号链接：$wallet_osense_jar_target"
		return 1
	fi
	if [[ -f "$wallet_osense_jar_target" ]]; then
		skip_print "OSense stub jar 已存在"
		return 0
	fi
	check_file_exists "$patcher_dir/prebuilt/framework/oplus-osense-stub.jar" || return 1
	mkdir -p -- "$(dirname -- "$wallet_osense_jar_target")"
	copy_file_missing_only "$patcher_dir/prebuilt/framework/oplus-osense-stub.jar" \
		"$wallet_osense_jar_target"
	append_wallet_metadata_patch fsconfig_system 'system/system/framework/oplus-osense-stub.jar 0 0 0644'
	append_wallet_metadata_patch contexts_system '/system/system/framework/oplus-osense-stub\.jar u:object_r:system_file:s0'
	std_print "✅ OSense stub jar 已写入 system framework"
}

inject_zygote_bootclasspath() {
	if [[ -L "$wallet_zygote_rc_target" ]]; then
		err_print "zygote rc 目标不能是符号链接：$wallet_zygote_rc_target"
		return 1
	elif [[ ! -f "$wallet_zygote_rc_target" ]]; then
		warn_print "zygote rc 不存在，跳过 BOOTCLASSPATH 注入：${wallet_zygote_rc_target#"$project_dir"/}"
		return 0
	fi
	if grep -q 'oplus-osense-stub' "$wallet_zygote_rc_target"; then
		skip_print "zygote BOOTCLASSPATH 已包含 OSense stub"
		return 0
	fi
	check_file_exists "$wallet_bcp_file" || return 1
	local boot_classpath
	boot_classpath="$(head -n1 "$wallet_bcp_file")"
	if [[ -z "$boot_classpath" || "$boot_classpath" == *[[:space:]]* ]]; then
		err_print "BOOTCLASSPATH 值无效（需为无空格单行）：$wallet_bcp_file"
		return 1
	fi
	local patched_rc
	patched_rc="$(mktemp "$(get_config_path '.zygote64.rc.XXXXXX')")"
	wallet_rc_patch_files+=("$patched_rc")
	awk -v bcp="$boot_classpath" '
		{ print }
		/^service zygote / && !done {
			print "    setenv BOOTCLASSPATH " bcp ":/system/framework/oplus-osense-stub.jar"
			done = 1
		}
		END { exit(done ? 0 : 3) }
	' "$wallet_zygote_rc_target" > "$patched_rc" || {
		rm -f -- "$patched_rc"
		err_print "zygote rc 中未找到 service zygote 定义"
		return 1
	}
	replace_file_if_different "$patched_rc" "$wallet_zygote_rc_target"
	std_print "✅ zygote BOOTCLASSPATH 已注入 OSense stub"
}

install_wallet_props_rc
install_osense_stub
inject_zygote_bootclasspath

# ── 身份键 build.prop 修正 ─────────────────────────────────────────
# init 的 PropertySet 拒绝覆盖已存在的 ro. 属性（post-fs-data rc setprop 对
# brand/manufacturer 无效，仅对属性表中不存在的 cuptsm/oplusrom 等首次设置
# 有效），因此品牌键必须在加载期就是正确值：
#   - odm/etc/build.prop 的分区键 odm.brand/manufacturer=OnePlus：Android 12+
#     分区键回填优先于普通键，是 Build.BRAND 的最终决定者；
#   - system/system/build.prop 普通键：原包污染源，双重兜底；
#   - 本模块必须在组合流程中位于 common/fix_device_identity 之后，否则会被其
#     mi_odm 快照（Xiaomi）覆盖。
# cuptsm 实测被 init 加载路径丢弃（属性表不存在，机制待查），rc setprop 与
# build.prop 双写互为保险。
fix_identity_build_props() {
	local odm_etc_build_prop="$project_dir/odm/etc/build.prop"
	local odm_build_prop="$project_dir/odm/build.prop"
	local system_build_prop="$project_dir/system/system/build.prop"
	local -a identity_targets=(
		"odm.brand=OnePlus"
		"odm.manufacturer=OnePlus"
		# 机型身份真值（2026-09-16 主系统 OP6117L1 实测）：Build.MODEL/DEVICE 由
		# odm 分区键回填决定，必须写 odm 分区键（system 普通键仅作 native 兜底）。
		# odm.device 由 nezha 改 OP6117L1 后，小爱 fix_xiaoai_voicetrigger 的
		# XIAOAI_VOICEASSIST_DEVICE_CODE 已同步改 OP6117L1（OPAce6T_port.sh）。
		"odm.device=OP6117L1"
		"odm.model=PLR110"
		"odm.name=PLR110"
	)
	local entry key value

	if [[ -L "$odm_etc_build_prop" || -L "$odm_build_prop" || -L "$system_build_prop" ]]; then
		err_print "身份键 build.prop 目标不能是符号链接"
		return 1
	fi
	for entry in "${identity_targets[@]}"; do
		key="${entry%%=*}"
		value="${entry#*=}"
		ensure_prop "$odm_etc_build_prop" "ro.product.$key" "$value"
		ensure_prop "$odm_build_prop" "ro.product.$key" "$value"
	done
	ensure_prop "$system_build_prop" "ro.product.brand" "OnePlus"
	ensure_prop "$system_build_prop" "ro.product.manufacturer" "OnePlus"
	# 机型身份真值（2026-09-16 主系统 OP6117L1 / ColorOS V16.1.0 实测）：
	# 钱包 fdid 设备指纹服务按 (model, device) 校验，移植系统残留
	# model=2512BPNDAC/device=nezha 时报"机型不匹配"→ 乘车卡列表空 +
	# 门禁复制 291005"获取机型及芯片类型异常"（VendorService CPLC 已非空，
	# 唯一缺口是机型身份）。真值：model/name=PLR110、device=OP6117L1。
	# 注意：Build.DEVICE 随 odm 分区键变为 OP6117L1，小爱白名单已由
	# OPAce6T_port.sh 的 XIAOAI_VOICEASSIST_DEVICE_CODE 同步；此处的
	# system 普通键为 native 路径兜底。
	ensure_prop "$system_build_prop" "ro.product.device" "OP6117L1"
	ensure_prop "$system_build_prop" "ro.product.model" "PLR110"
	ensure_prop "$system_build_prop" "ro.product.name" "PLR110"
	ensure_prop "$system_build_prop" "ro.product.marketname" "一加 Ace 6T"
	# cuptsm 值含竖线，确保 prop 文件校验通过（read_prop_value/validate 已支持）。
	ensure_prop "$odm_build_prop" "ro.product.cuptsm" "ONEPLUS|ESE|01|02"
	ensure_prop "$odm_etc_build_prop" "ro.product.cuptsm" "ONEPLUS|ESE|01|02"
	ensure_prop "$system_build_prop" "ro.product.cuptsm" "ONEPLUS|ESE|01|02"
	ensure_prop "$system_build_prop" "ro.build.version.oplusrom" "V16.1.0"
	ensure_prop "$system_build_prop" "ro.build.version.oplusrom.display" "16.1"
	std_print "✅ 钱包身份键已修正到 odm/system build.prop（加载期生效）"
}

fix_identity_build_props

# ── 系统侧 APK 固化（无签名约束，apk_patcher 幂等补丁）────────────────
# 1) com.android.se：eSE OMAPI 访问白名单。底包 eSE 的 ARA-M 只放行银联
#    UPTsmService 证书与 com.nxp.security，钱包/卡包证书被拒导致
#    "获取CPLC失败"（真机 2026-09-15 AccessControlException 实证）。
#    补丁在 Terminal.isPrivilegedApplication 入口追加钱包包名白名单，
#    命中即走 ChannelAccess.getPrivilegeAccess（全 ALLOWED）绕过 ARA-M。
# 2) MIUI Settings：补齐 AOSP 旧类名 com.android.settings.nfc.PaymentSettings。
#    钱包经 android.settings.NFC_PAYMENT_SETTINGS 跳"感应式支付"页，MIUI 已把
#    实现改名 DefaultPaymentSettings 但别名仍指旧类名，Fragment 实例化失败
#    导致页面只有标题没有内容。补丁新增 DefaultPaymentSettings 空壳子类。
patch_secure_element_apk() {
	local se_apk_target="$project_dir/system/system/app/SecureElement/SecureElement.apk"
	if [[ -L "$se_apk_target" ]]; then
		err_print "SecureElement.apk 目标不能是符号链接：$se_apk_target"
		return 1
	fi
	if [[ ! -f "$se_apk_target" ]]; then
		warn_print "原包 system 未找到 SecureElement.apk，跳过 eSE 白名单补丁：${se_apk_target#"$project_dir"/}"
		return 0
	fi
	bash "$patcher_dir/patch_secure_element.sh" "$se_apk_target"
}

patch_settings_nfc_payment_apk() {
	local settings_apk_target="$project_dir/system_ext/priv-app/Settings/Settings.apk"
	if [[ -L "$settings_apk_target" ]]; then
		err_print "Settings.apk 目标不能是符号链接：$settings_apk_target"
		return 1
	fi
	if [[ ! -f "$settings_apk_target" ]]; then
		warn_print "原包 system_ext 未找到 Settings.apk，跳过感应式支付页补丁：${settings_apk_target#"$project_dir"/}"
		return 0
	fi
	bash "$patcher_dir/patch_settings_nfc_payment.sh" "$settings_apk_target"
}

patch_secure_element_apk
patch_settings_nfc_payment_apk

# ── 欢太账号（com.oplus.account，第六依赖）──────────────────────────
# 钱包登录/云端 TSM 流程（复制门禁卡、乘车卡）依赖欢太账号鉴权：缺包时
# As-TaskGetToken -202（登录无反应），门禁 /nfc/door/v1/check-condition 返回
# 99990 用户鉴权失败、乘车卡列表为空，页面在 onCreate 检查阶段自行 finish
# （真机 2026-09-15 实证）。底包 ColorOS 16 中账号应用位于
# /product/priv-app/KeKeUserCenterAccount（包名 com.oplus.account，manifest
# 同时声明 heytap/oppo usercenter 兼容名）；与 FinShell 5.47.5 同出自 PLR110，
# 为配套版本。priv-app 需要配套权限白名单，缺失项按被拒处理（与底包一致）。
install_heytap_account() {
	local account_dir_target="$project_dir/system_ext/priv-app/KeKeUserCenterAccount"
	local account_apk_target="$account_dir_target/KeKeUserCenterAccount.apk"
	local account_perm_source="$patcher_dir/prebuilt/system_ext/etc/permissions/privapp-permissions-keke-usercenter.xml"
	local account_perm_target="$project_dir/system_ext/etc/permissions/privapp-permissions-keke-usercenter.xml"
	local account_source_apk="$prebuilt_root/system_ext/priv-app/KeKeUserCenterAccount/KeKeUserCenterAccount.apk"

	if [[ ! -f "$account_source_apk" ]]; then
		warn_print "欢太账号预置缺失：prebuilt/system_ext/priv-app/KeKeUserCenterAccount/KeKeUserCenterAccount.apk（登录与云端 TSM 功能不可用）"
		return 0
	fi
	if [[ -L "$account_dir_target" || -L "$account_apk_target" || -L "$account_perm_target" ]]; then
		err_print "欢太账号目标不能是符号链接"
		return 1
	fi
	mkdir -p -- "$account_dir_target" "$(dirname -- "$account_perm_target")"
	copy_tree_missing_only "$prebuilt_root/system_ext/priv-app/KeKeUserCenterAccount" "$account_dir_target"
	copy_file_missing_only "$account_perm_source" "$account_perm_target"
	append_wallet_metadata_patch fsconfig_system \
		'system_ext/priv-app/KeKeUserCenterAccount/KeKeUserCenterAccount.apk 0 0 0644'
	append_wallet_metadata_patch fsconfig_system \
		'system_ext/etc/permissions/privapp-permissions-keke-usercenter.xml 0 0 0644'
	append_wallet_metadata_patch contexts_system \
		'/system_ext/priv-app/KeKeUserCenterAccount(/.*)? u:object_r:system_file:s0'
	append_wallet_metadata_patch contexts_system \
		'/system_ext/etc/permissions/privapp-permissions-keke-usercenter\.xml u:object_r:system_file:s0'
	std_print "✅ 欢太账号已就绪（system_ext/priv-app/KeKeUserCenterAccount）"
}

install_heytap_account

std_print "处理完成"
