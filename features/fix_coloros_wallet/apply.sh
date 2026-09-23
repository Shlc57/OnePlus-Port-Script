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

# ── 机型身份真值（由组合入口 WALLET_IDENTITY_PROPERTIES_FILE 提供，特性模块不写死）──
# 品牌/机型/cuptsm（SE 厂商专有）/oplusrom（底包 ColorOS 版本）均为机型/ROM 专有，
# 标准 PORT_BASE_DEVICE_* 不含 brand/cuptsm/oplusrom，故整份身份真值由机型入口 .props 提供。
wallet_identity_file="${WALLET_IDENTITY_PROPERTIES_FILE:-}"
if [[ -z "$wallet_identity_file" ]]; then
	err_print "未提供 WALLET_IDENTITY_PROPERTIES_FILE：钱包身份键须来自机型 .props，不在特性模块写死某机型"
	exit 1
fi
if [[ -L "$wallet_identity_file" || ! -f "$wallet_identity_file" ]]; then
	err_print "WALLET_IDENTITY_PROPERTIES_FILE 不是普通文件：$wallet_identity_file"
	exit 1
fi
wallet_identity_prop() {
	local key="$1"
	awk -F'=' -v k="$key" '$0 ~ "^[[:space:]]*"k"[[:space:]]*="{v=substr($0,index($0,"=")+1);gsub(/^[ \t]+|[ \t]+$/,"",v);print v;exit}' "$wallet_identity_file"
}
declare -A WALLET_ID=()
declare -a wallet_identity_required=(brand manufacturer device model name marketname cuptsm oplusrom oplusrom_display)
wallet_identity_key=''
for wallet_identity_key in "${wallet_identity_required[@]}"; do
	WALLET_ID["$wallet_identity_key"]="$(wallet_identity_prop "$wallet_identity_key")"
	if [[ -z "${WALLET_ID[$wallet_identity_key]}" ]]; then
		err_print "机型身份 .props 缺少必填键：$wallet_identity_key（$wallet_identity_file）"
		exit 1
	fi
done
# region/regionmark 可选，默认 CN（中国区 SKU）。
WALLET_ID[regionmark]="$(wallet_identity_prop regionmark)"; [[ -n "${WALLET_ID[regionmark]}" ]] || WALLET_ID[regionmark]='CN'
WALLET_ID[region]="$(wallet_identity_prop region)"; [[ -n "${WALLET_ID[region]}" ]] || WALLET_ID[region]='CN'

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
#    注入值来自旧 DSU 运行时捕获的静态快照（原包更新后需重新捕获）；曾尝试
#    向 bootclasspath.pb 追加贡献条目做动态化，真机验证钱包仍闪退（stub 未
#    进入 BCP），已回退为快照注入，遇原包 BCP 结构变化再重新适配。

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
		fsconfig_system_ext)
			merge_fsconfig_file "$patch_file" "$(get_part_fsconfig_path system_ext)" ;;
		contexts_system_ext)
			merge_contexts_file "$patch_file" "$(get_part_contexts_path system_ext)" ;;
		*)
			err_print "未知 metadata 类型：$kind"
			return 1
			;;
	esac
}

install_wallet_props_rc() {
	local generated_rc
	if [[ -L "$wallet_props_rc_target" ]]; then
		err_print "钱包身份键 rc 目标不能是符号链接：$wallet_props_rc_target"
		return 1
	fi
	# rc 内容由机型身份 .props 生成，不再复制写死某机型的静态 prebuilt rc。
	generated_rc="$(mktemp "$(get_config_path '.wallet_props_rc.XXXXXX')")"
	temporary_files+=("$generated_rc")
	{
		printf '# ColorOS 钱包运行时身份键（features/fix_coloros_wallet，由机型 .props 生成）。\n'
		printf '# 品牌/机型/cuptsm/oplusrom 由组合入口 WALLET_IDENTITY_PROPERTIES_FILE 提供，避免写死某机型。\n'
		printf 'on post-fs-data\n'
		printf '    setprop ro.product.brand %s\n' "${WALLET_ID[brand]}"
		printf '    setprop ro.product.manufacturer %s\n' "${WALLET_ID[manufacturer]}"
		printf '    setprop ro.build.version.oplusrom %s\n' "${WALLET_ID[oplusrom]}"
		printf '    setprop ro.build.version.oplusrom.display %s\n' "${WALLET_ID[oplusrom_display]}"
		printf '    setprop ro.product.cuptsm "%s"\n' "${WALLET_ID[cuptsm]}"
		printf '    setprop ro.vendor.oplus.regionmark %s\n' "${WALLET_ID[regionmark]}"
		printf '    setprop persist.sys.oplus.region %s\n' "${WALLET_ID[region]}"
		printf '    setprop persist.sys.oppo.region %s\n' "${WALLET_ID[region]}"
	} > "$generated_rc"
	if [[ -f "$wallet_props_rc_target" ]]; then
		if ! grep -q 'ColorOS 钱包运行时身份键' "$wallet_props_rc_target"; then
			err_print "钱包身份键 rc 目标已被无关内容占用：${wallet_props_rc_target#"$project_dir"/}"
			return 1
		fi
		# replace_file_if_different 保留目标原模式（0644），内容相同则幂等跳过。
		replace_file_if_different "$generated_rc" "$wallet_props_rc_target"
		skip_print "钱包身份键 rc 已按机型 .props 同步"
	else
		mkdir -p -- "$project_dir/odm/etc/init"
		mv -f -- "$generated_rc" "$wallet_props_rc_target"
		chmod 0644 -- "$wallet_props_rc_target"
		std_print "✅ 钱包身份键 rc 已按机型 .props 生成到 odm"
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
	check_file_exists "$wallet_bcp_file" || return 1
	local boot_classpath
	boot_classpath="$(head -n1 "$wallet_bcp_file")"
	if [[ -z "$boot_classpath" || "$boot_classpath" == *[[:space:]]* ]]; then
		err_print "BOOTCLASSPATH 值无效（需为无空格单行）：$wallet_bcp_file"
		return 1
	fi
	# 快照是旧 DSU 运行时捕获值；原包更新后 jar 可能改名。apex jar 内容无法在
	# 打包侧静态校验，但 system/system_ext 条目可校验，缺失说明快照已过期，
	# 必须在写入工作树前失败，否则 zygote 因 boot classpath 缺条目而崩溃循环。
	local jar bcp_target
	while IFS= read -r jar; do
		[[ -n "$jar" ]] || continue
		case "$jar" in
			/system/*) bcp_target="$project_dir/system$jar" ;;
			/system_ext/*) bcp_target="$project_dir$jar" ;;
			/apex/*) continue ;;
			*)
				err_print "BOOTCLASSPATH 快照条目前缀无法识别：$jar"
				return 1
				;;
		esac
		if [[ ! -f "$bcp_target" ]]; then
			err_print "BOOTCLASSPATH 快照引用的 jar 在目标工程不存在（原包更新后快照过期，需重新捕获）：$jar"
			return 1
		fi
	done < <(tr ':' '\n' <<<"$boot_classpath")
	# 注入行必须精确等于快照值 + stub。原包 rc 若自带 setenv BOOTCLASSPATH（旧版
	# HyperOS 结构），init 按后出现的 setenv 生效，只追加会导致 stub 被原包值覆盖，
	# 因此必须在 service zygote 块内剔除全部 setenv BOOTCLASSPATH 行后重写；块外
	# （如 service zygote-secondary）的同名 setenv 不属于本服务，不得误删。
	local expected_line="    setenv BOOTCLASSPATH ${boot_classpath}:/system/framework/oplus-osense-stub.jar"
	local patched_rc
	patched_rc="$(mktemp "$(get_config_path '.zygote64.rc.XXXXXX')")"
	temporary_files+=("$patched_rc")
	awk -v bcp_line="$expected_line" '
		/^service zygote / && !done {
			print
			print bcp_line
			inblock = 1
			done = 1
			next
		}
		inblock && /^[[:space:]]/ {
			if ($0 ~ /setenv[[:space:]]+BOOTCLASSPATH/) {
				next
			}
			print
			next
		}
		{
			inblock = 0
			print
		}
		END { exit(done ? 0 : 3) }
	' "$wallet_zygote_rc_target" > "$patched_rc" || {
		rm -f -- "$patched_rc"
		err_print "zygote rc 中未找到 service zygote 定义"
		return 1
	}
	if cmp -s -- "$patched_rc" "$wallet_zygote_rc_target"; then
		skip_print "zygote BOOTCLASSPATH 注入值已是最新"
		return 0
	fi
	# replace_file_if_different 替换既有普通文件时保留目标模式（原包 rc 为 0644）。
	replace_file_if_different "$patched_rc" "$wallet_zygote_rc_target"
	std_print "✅ zygote BOOTCLASSPATH 已注入 OSense stub"
}

install_nfc_multise_settings() {
	local rc_target="$project_dir/odm/etc/init/coloros_wallet_nfc_settings.rc"
	local script_target="$project_dir/odm/etc/init/coloros_wallet_nfc_settings.sh"
	if [[ -L "$rc_target" || -L "$script_target" ]]; then
		err_print "钱包 NFC 设置 rc/脚本目标不能是符号链接：$rc_target $script_target"
		return 1
	fi
	if [[ -f "$rc_target" && -f "$script_target" ]]; then
		skip_print "钱包 NFC 运行时设置 rc/脚本已存在，同步 metadata"
	else
		check_file_exists "$patcher_dir/prebuilt/odm_init/coloros_wallet_nfc_settings.rc" || return 1
		check_file_exists "$patcher_dir/prebuilt/odm_init/coloros_wallet_nfc_settings.sh" || return 1
		mkdir -p -- "$project_dir/odm/etc/init"
		copy_file_missing_only "$patcher_dir/prebuilt/odm_init/coloros_wallet_nfc_settings.rc" \
			"$rc_target"
		copy_file_missing_only "$patcher_dir/prebuilt/odm_init/coloros_wallet_nfc_settings.sh" \
			"$script_target"
		std_print "✅ 钱包 NFC 运行时设置 rc/脚本已写入 odm"
	fi
	# shell 域 exec_background 需要读取脚本，contexts 与 props rc 同用 vendor_configs_file。
	append_wallet_metadata_patch fsconfig 'odm/etc/init/coloros_wallet_nfc_settings.rc 0 0 0644'
	append_wallet_metadata_patch fsconfig 'odm/etc/init/coloros_wallet_nfc_settings.sh 0 0 0644'
	append_wallet_metadata_patch contexts '/odm/etc/init/coloros_wallet_nfc_settings\.rc u:object_r:vendor_configs_file:s0'
	append_wallet_metadata_patch contexts '/odm/etc/init/coloros_wallet_nfc_settings\.sh u:object_r:vendor_configs_file:s0'
}

install_wallet_props_rc
install_nfc_multise_settings
install_osense_stub
inject_zygote_bootclasspath

# ── 机型身份 build.prop 修正（真值来自组合入口 .props，见 WALLET_IDENTITY_PROPERTIES_FILE）
# init 的 PropertySet 拒绝覆盖已存在的 ro. 属性（post-fs-data rc setprop 仅对属性表中
# 不存在的 cuptsm/oplusrom 首次设置有效），因此品牌/机型键必须在加载期就是正确值：
#   - odm/etc/build.prop 的分区键 ro.product.odm.* 回填优先，是 Build.BRAND/MODEL/DEVICE
#     的最终决定者；system/system/build.prop 普通键为 native 兜底；
#   - 本模块必须在组合流程中位于 common/fix_device_identity 之后，否则会被其原包快照覆盖；
#   - device/model 真值决定钱包 fdid 校验，且会改变运行时 Build.DEVICE；组合入口须用
#     RUNTIME_DEVICE_CODE 同步机型 XML 改名，并用 XIAOAI_VOICEASSIST_DEVICE_CODE 同步白名单。
fix_identity_build_props() {
	local odm_etc_build_prop="$project_dir/odm/etc/build.prop"
	local odm_build_prop="$project_dir/odm/build.prop"
	local system_build_prop="$project_dir/system/system/build.prop"
	local -a identity_targets=(
		"odm.brand=${WALLET_ID[brand]}"
		"odm.manufacturer=${WALLET_ID[manufacturer]}"
		"odm.device=${WALLET_ID[device]}"
		"odm.model=${WALLET_ID[model]}"
		"odm.name=${WALLET_ID[name]}"
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
	ensure_prop "$system_build_prop" "ro.product.brand" "${WALLET_ID[brand]}"
	ensure_prop "$system_build_prop" "ro.product.manufacturer" "${WALLET_ID[manufacturer]}"
	ensure_prop "$system_build_prop" "ro.product.device" "${WALLET_ID[device]}"
	ensure_prop "$system_build_prop" "ro.product.model" "${WALLET_ID[model]}"
	ensure_prop "$system_build_prop" "ro.product.name" "${WALLET_ID[name]}"
	ensure_prop "$system_build_prop" "ro.product.marketname" "${WALLET_ID[marketname]}"
	# cuptsm 值含竖线但无空格，ensure_prop 原样写入；rc setprop 与 build.prop 双写互为保险。
	ensure_prop "$odm_build_prop" "ro.product.cuptsm" "${WALLET_ID[cuptsm]}"
	ensure_prop "$odm_etc_build_prop" "ro.product.cuptsm" "${WALLET_ID[cuptsm]}"
	ensure_prop "$system_build_prop" "ro.product.cuptsm" "${WALLET_ID[cuptsm]}"
	ensure_prop "$system_build_prop" "ro.build.version.oplusrom" "${WALLET_ID[oplusrom]}"
	ensure_prop "$system_build_prop" "ro.build.version.oplusrom.display" "${WALLET_ID[oplusrom_display]}"
	std_print "✅ 钱包身份键已修正到 odm/system build.prop（机型 ${WALLET_ID[model]}/${WALLET_ID[device]}，加载期生效）"
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
	# KeKe 文件在 system_ext 分区：metadata 必须写入 system_ext 的
	# contexts/fsconfig。历史版本误写 system 分区，打包后该路径无逐文件
	# 条目被打成 unlabeled（真机 2026-09-17 实证），并在此清理残留条目。
	remove_contexts_prefix "$(get_part_contexts_path system)" \
		"/system_ext/priv-app/KeKeUserCenterAccount" || return 1
	remove_contexts_prefix "$(get_part_contexts_path system)" \
		"/system_ext/etc/permissions/privapp-permissions-keke-usercenter.xml" || return 1
	append_wallet_metadata_patch fsconfig_system_ext \
		'system_ext/priv-app/KeKeUserCenterAccount/KeKeUserCenterAccount.apk 0 0 0644'
	append_wallet_metadata_patch fsconfig_system_ext \
		'system_ext/etc/permissions/privapp-permissions-keke-usercenter.xml 0 0 0644'
	append_wallet_metadata_patch contexts_system_ext \
		'/system_ext/priv-app/KeKeUserCenterAccount(/.*)? u:object_r:system_file:s0'
	append_wallet_metadata_patch contexts_system_ext \
		'/system_ext/etc/permissions/privapp-permissions-keke-usercenter\.xml u:object_r:system_file:s0'
	std_print "✅ 欢太账号已就绪（system_ext/priv-app/KeKeUserCenterAccount）"
}

install_heytap_account

std_print "处理完成"
