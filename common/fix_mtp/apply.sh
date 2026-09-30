#!/bin/bash
set -euo pipefail

patcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

init_port_env "${1:-}"

# 两种装配模式，由机型组合入口选择：
#   replace（默认）：用底包 init.usb.configfs.rc 覆盖 system 那份（一加 15 / Ace 6 / Ace 6T）。
#   gate：不覆盖整份 rc，只校正 vendor.usb.use_ffs_mtp 与 system rc 里 mtp/mtp,adb 两条装配门
#           （Qti `use_ffs_mtp` 机型，当前：真我 Neo8）。该模式不引入任何机型硬编码：
#           属性目标值由入口的 FIX_MTP_FFS_VALUE 提供。
fix_mtp_mode="${FIX_MTP_MODE:-replace}"
case "$fix_mtp_mode" in
	replace)
		std_print "修复 MTP USB 配置"
		std_print "使用 init.usb.configfs.rc 中的底包配置"
		;;
	gate)
		std_print "修复 MTP USB 配置（装配门模式）"
		std_print "不覆盖 system rc，只校正 vendor.usb.use_ffs_mtp 与 mtp/mtp,adb 两条装配门"
		;;
	*)
		err_print "未知的 FIX_MTP_MODE：$fix_mtp_mode（支持 replace|gate）"
		exit 1
		;;
esac
std_print

check_part_exists system

if [[ "$fix_mtp_mode" == "gate" ]]; then
	gm_ffs_value="${FIX_MTP_FFS_VALUE:-}"
	case "$gm_ffs_value" in
		0|1) ;;
		*)
			err_print "gate 模式必须由组合入口提供 FIX_MTP_FFS_VALUE=0 或 1（当前：${gm_ffs_value:-<未设置>}）"
			exit 1
			;;
	esac
	gm_prop_key='vendor.usb.use_ffs_mtp'
	# project_dir 由 tools.sh 的 init_port_env 注入。
	# shellcheck disable=SC2154
	gm_vendor_prop="$project_dir/vendor/build.prop"
	gm_usb_rc="$project_dir/system/system/etc/init/hw/init.usb.configfs.rc"
	gm_changed=0
	gm_skipped=0

	check_part_exists vendor

	# 第一步：属性子步骤为可选。文件缺失只警告并跳过本子步骤，不提前退出，
	# 否则“属性已正确”的工作树会错过第二步的装配门修正。
	if [[ -L "$gm_vendor_prop" ]]; then
		err_print "不支持直接修改符号链接：$gm_vendor_prop"
		exit 1
	elif [[ ! -e "$gm_vendor_prop" ]]; then
		warn_print "vendor build.prop 不存在，跳过 MTP 属性适配：${gm_vendor_prop#"$project_dir"/}"
	elif [[ ! -f "$gm_vendor_prop" ]]; then
		err_print "vendor build.prop 不是普通文件：$gm_vendor_prop"
		exit 1
	else
		gm_current="$(read_prop_value "$gm_prop_key" "$gm_vendor_prop" 2>/dev/null)" || gm_current=''
		if [[ "$gm_current" == "$gm_ffs_value" ]]; then
			skip_print "${gm_prop_key} 已是 ${gm_ffs_value}，跳过属性写入"
		else
			if ! ensure_prop "$gm_vendor_prop" "$gm_prop_key" "$gm_ffs_value"; then
				err_print "写入 ${gm_prop_key}=${gm_ffs_value} 失败：${gm_vendor_prop#"$project_dir"/}"
				exit 1
			fi
			gm_new="$(read_prop_value "$gm_prop_key" "$gm_vendor_prop" 2>/dev/null)" || gm_new=''
			if [[ "$gm_new" != "$gm_ffs_value" ]]; then
				err_print "${gm_prop_key} 写入后校验失败（期望 ${gm_ffs_value}，实际 ${gm_new:-<空>}）"
				exit 1
			fi
			std_print "✅ 已置 ${gm_prop_key}=${gm_ffs_value}（原值 ${gm_current:-<未设置>}）"
			gm_changed=1
		fi
	fi

	# 第二步：把 mtp / mtp,adb 两条装配分支的门收敛到 use_ffs_mtp=<FIX_MTP_FFS_VALUE>。
	# 每个目标分支接受两条待改旧门：原厂 MIUI 的 ro.boot.ramdump=disable，以及
	# 属性值为另一侧时的 use_ffs_mtp=<反值>（上一版补丁形态），保证可重复执行。
	declare -a gm_target=(
		"on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:${gm_prop_key}=${gm_ffs_value}"
		"on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:${gm_prop_key}=${gm_ffs_value}"
	)
	declare -a gm_old=(
		"on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:ro.boot.ramdump=disable"
		"on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:${gm_prop_key}=$((1 - gm_ffs_value))"
		"on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:ro.boot.ramdump=disable"
		"on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:${gm_prop_key}=$((1 - gm_ffs_value))"
	)
	declare -a gm_new_line=("${gm_target[0]}" "${gm_target[0]}" "${gm_target[1]}" "${gm_target[1]}")

	if [[ -L "$gm_usb_rc" ]]; then
		err_print "不支持直接修改符号链接：system/system/etc/init/hw/init.usb.configfs.rc"
		exit 1
	elif [[ ! -e "$gm_usb_rc" ]]; then
		warn_print "MTP 触发器目标不存在，跳过改写 mtp/mtp,adb 装配门：system/system/etc/init/hw/init.usb.configfs.rc"
	elif [[ ! -f "$gm_usb_rc" ]]; then
		err_print "MTP 触发器目标不是普通文件：system/system/etc/init/hw/init.usb.configfs.rc"
		exit 1
	else
		# 先全量校验：每条目标分支要么已是目标形态，要么至少能找到一条待改的旧门；
		# 两者都找不到则失败，避免 HyperOS 版本变化后静默不生效。
		for gm_group in 0 1; do
			gm_want="${gm_target[$gm_group]}"
			gm_a="${gm_old[$((gm_group * 2))]}"
			gm_b="${gm_old[$((gm_group * 2 + 1))]}"
			if ! grep -Fxq -- "$gm_want" "$gm_usb_rc" && \
				! grep -Fxq -- "$gm_a" "$gm_usb_rc" && \
				! grep -Fxq -- "$gm_b" "$gm_usb_rc"; then
				err_print "未找到预期的 MTP 触发器，不能确认装配门形态：$gm_want"
				exit 1
			fi
		done

		gm_temp="$(mktemp "${gm_usb_rc}.gate.XXXXXX")"
		gm_cleanup() {
			if [[ -n "${gm_temp:-}" ]]; then
				rm -f -- "$gm_temp"
			fi
			return 0
		}
		trap gm_cleanup EXIT
		if ! awk -v o1="${gm_old[0]}" -v n1="${gm_new_line[0]}" \
			-v o2="${gm_old[1]}" -v n2="${gm_new_line[1]}" \
			-v o3="${gm_old[2]}" -v n3="${gm_new_line[2]}" \
			-v o4="${gm_old[3]}" -v n4="${gm_new_line[3]}" '
			{
				if ($0 == o1) { print n1; next }
				if ($0 == o2) { print n2; next }
				if ($0 == o3) { print n3; next }
				if ($0 == o4) { print n4; next }
				print
			}
		' "$gm_usb_rc" > "$gm_temp"; then
			err_print "改写 init.usb.configfs.rc 的 MTP 装配门失败"
			exit 1
		fi
		for gm_want in "${gm_target[@]}"; do
			if ! grep -Fxq -- "$gm_want" "$gm_temp"; then
				err_print "MTP 装配门改写后缺少预期条目：$gm_want"
				exit 1
			fi
		done
		for gm_stale in "${gm_old[@]}"; do
			if grep -Fxq -- "$gm_stale" "$gm_temp"; then
				err_print "MTP 装配门改写后仍残留旧门：$gm_stale"
				exit 1
			fi
		done
		if cmp -s -- "$gm_temp" "$gm_usb_rc"; then
			gm_skipped=1
		elif ! replace_file_if_different "$gm_temp" "$gm_usb_rc"; then
			err_print "写回 init.usb.configfs.rc 失败"
			exit 1
		else
			gm_changed=1
		fi
		gm_cleanup
		trap - EXIT
		if (( gm_skipped == 1 && gm_changed == 0 )); then
			skip_print "init.usb.configfs.rc 的 mtp/mtp,adb 装配门已是目标形态"
		elif (( gm_skipped == 1 )); then
			skip_print "init.usb.configfs.rc 的 mtp/mtp,adb 装配门已是目标形态（仅属性有变更）"
		else
			std_print "✅ 已把 mtp/mtp,adb 装配分支门收敛为 property:${gm_prop_key}=${gm_ffs_value}"
		fi
	fi

	std_print "处理完成"
	exit 0
fi

# 默认使用模块内置的一加 15 底包 rc；其他底包由组合入口通过
# FIX_MTP_SOURCE_RC 提供本机型来源，缺失或类型错误时失败。
source_file="$patcher_dir/init.usb.configfs.rc"
if [[ -n "${FIX_MTP_SOURCE_RC:-}" ]]; then
	source_file="${FIX_MTP_SOURCE_RC}"
fi
# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
target_file="$project_dir/system/system/etc/init/hw/init.usb.configfs.rc"
check_file_exists "$source_file" "底包 init.usb.configfs.rc（FIX_MTP_SOURCE_RC 或模块内置）"
if [[ -L "$source_file" ]]; then
	err_print "MTP 配置源文件必须是普通文件：$source_file"
	exit 1
fi

# 触发器校验按来源 rc 的实际形态自适应：
# - 底包 rc 引用 vendor.usb.use_ffs_mtp（如一加 15）时，要求完整的 5 个触发器；
# - 底包 rc 走 mtp.gs0 纯触发器（如一加 Ace 6 系列）时，只要求 3 个基础触发器。
if grep -Fq 'property:vendor.usb.use_ffs_mtp' "$source_file"; then
	required_triggers=(
		'on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=0'
		'on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=1'
		'on property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1'
		'on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=0'
		'on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=1'
	)
else
	required_triggers=(
		'on property:sys.usb.config=mtp && property:sys.usb.configfs=1'
		'on property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1'
		'on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1'
	)
fi
for trigger in "${required_triggers[@]}"; do
	if ! grep -Fqx "$trigger" "$source_file"; then
		err_print "底包 init.usb.configfs.rc 缺少 MTP 触发器：$trigger"
		exit 1
	fi
done

if [[ -L "$target_file" ]]; then
	err_print "不支持替换符号链接 MTP 配置：$target_file"
	exit 1
elif [[ ! -e "$target_file" ]]; then
	warn_print "待替换的 MTP 配置不存在，跳过：${target_file#"$project_dir"/}"
	std_print "处理完成"
	exit 0
elif [[ ! -f "$target_file" ]]; then
	err_print "待替换的 MTP 配置不是普通文件：$target_file"
	exit 1
fi

temporary_file="$(mktemp "${target_file}.tmp.XXXXXX")"
cleanup() {
	rm -f -- "$temporary_file"
}
trap cleanup EXIT

cp -- "$source_file" "$temporary_file"
_install_generated_file "$temporary_file" "$target_file"

if ! cmp -s -- "$source_file" "$target_file"; then
	err_print "init.usb.configfs.rc 替换后校验失败"
	exit 1
fi

std_print "✅ 已从 init.usb.configfs.rc 替换 system/system/etc/init/hw/init.usb.configfs.rc"
std_print "处理完成"
