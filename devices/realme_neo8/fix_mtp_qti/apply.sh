#!/bin/bash
set -euo pipefail

# devices/realme_neo8/fix_mtp_qti/apply.sh
# 真我 Neo8 Qti MTP 适配（与 common/fix_mtp 机制不同，见 README 拆分理由）。
# 根因（底包分区取证 + Neo8 原系统真机采集修正）：
#   - Neo8 底包 vendor/build.prop: vendor.usb.use_ffs_mtp=1、use_gadget_hal=0，
#     纯 mtp/mtp,adb 在底包 vendor/etc/init/hw/init.qcom.usb.rc 只有 use_ffs_mtp=1
#     分支挂 ffs.mtp（第 1921/1934 行），=0 时仅写 idVendor/idProduct（第 1910/1925 行）。
#     =0 的 mtp.gs0 分支只存在于 mtp,diag* / mtp,mass_storage* 等厂商组合。
#   - HyperOS 移植侧用小米原包 system/system/etc/init/hw/init.usb.configfs.rc，其
#     mtp/mtp,adb 装配分支被 MIUI Charger_MIUIChargerFrame 加了
#     && property:ro.boot.ramdump=disable；Neo8 真机全量 getprop 没有 ro.boot.ramdump，
#     该分支永不触发（ptp/ptp,adb 无门，ramdump=enable 的是小米工程分支）。
#   - 因此单独把 use_ffs_mtp 翻成 0 会让 vendor 与 system 两侧都不挂任何 MTP function，
#     表现为“USB 用途只剩仅充电”。必须同时放开 system rc 的门，二者成对生效。
# 修法（两步必须成对生效，均为内容修改、不改路径/属主/权限，无需动 contexts/fsconfig）：
#   1) 把 vendor/build.prop 的 vendor.usb.use_ffs_mtp 置 0（该属性全树仅此一处定义、
#      无脚本动态改写），使底包 vendor 的 ffs.mtp 挂接与 zygote-start 的 functionfs
#      mtp/ptp 挂载（条件 =1）都不再触发，避免与 system 侧抢 f1。
#   2) 把 system init.usb.configfs.rc 的 mtp/mtp,adb 两条装配分支门从
#      ro.boot.ramdump=disable 换为 vendor.usb.use_ffs_mtp=0，使 HyperOS 侧真的会
#      symlink kernel mtp.gs0。
# 边界：ptp/ptp,adb 分支本就无门；mtp,diag* / mtp,mass_storage* 等厂商组合在底包
#   已有 use_ffs_mtp=0 的 mtp.gs0 分支，不受本模块影响；ramdump=enable 的小米工程
#   分支保持原样（Neo8 真机无 ro.boot.ramdump，两者不会并存触发）。
# 验证状态：症状与根因已由 Neo8 原系统真机采集（无 ro.boot.ramdump）+ 两侧 rc 取证
#   确定；翻转后的枚举与文件读写仍需 DSU 真机确认，未确认前不得记为已生效。

init_port_env "${1:-}"

std_print "修复 Neo8 Qti MTP：置 vendor.usb.use_ffs_mtp=0 并放开 HyperOS system rc 的 ramdump 门"
std_print

check_part_exists vendor
check_part_exists system

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
vendor_build_prop="$project_dir/vendor/build.prop"

prop_key='vendor.usb.use_ffs_mtp'
prop_value='0'

# 第一步：属性翻转。目标是可选 prop 子步骤：文件缺失只 warn 跳过本子步骤，
# 不提前退出整个补丁，否则“属性已是 0”的工作树会错过第二步的 rc 门修正。
if [[ -L "$vendor_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$vendor_build_prop"
	exit 1
elif [[ ! -e "$vendor_build_prop" ]]; then
	warn_print "vendor build.prop 不存在，跳过 MTP 属性适配：${vendor_build_prop#"$project_dir"/}"
elif [[ ! -f "$vendor_build_prop" ]]; then
	err_print "vendor build.prop 不是普通文件：$vendor_build_prop"
	exit 1
else
	current_value="$(read_prop_value "$prop_key" "$vendor_build_prop" 2>/dev/null)" || current_value=''
	if [[ "$current_value" == "$prop_value" ]]; then
		skip_print "${prop_key} 已是 ${prop_value}，跳过属性写入"
	else
		# ensure_prop 幂等：覆盖既有活动/注释条目为 key=0，缺失则追加，原子替换并保留模式。
		if ! ensure_prop "$vendor_build_prop" "$prop_key" "$prop_value"; then
			err_print "写入 ${prop_key}=${prop_value} 失败：${vendor_build_prop#"$project_dir"/}"
			exit 1
		fi
		new_value="$(read_prop_value "$prop_key" "$vendor_build_prop" 2>/dev/null)" || new_value=''
		if [[ "$new_value" != "$prop_value" ]]; then
			err_print "${prop_key} 写入后校验失败（期望 ${prop_value}，实际 ${new_value:-<空>}）"
			exit 1
		fi
		std_print "✅ 已置 ${prop_key}=${prop_value}（原值 ${current_value:-<未设置>}）：关闭底包 ffs.mtp 挂接，MTP 改由 HyperOS system rc 挂 kernel mtp.gs0"
	fi
fi

# 第二步：放开 system init.usb.configfs.rc 里 mtp / mtp,adb 两条装配分支的 MIUI 门。
# 真机取证（Neo8 原系统全量 getprop）里没有 ro.boot.ramdump，而 HyperOS 原包这两条
# 分支被 MIUI Charger_MIUIChargerFrame 加了 && property:ro.boot.ramdump=disable（无门行被注释），
# 所以在 Neo8 上永不触发；同时底包 vendor/etc/init/hw/init.qcom.usb.rc 对纯 mtp/mtp,adb
# 只在 use_ffs_mtp=1 时 symlink ffs.mtp，=0 时只写 idVendor/idProduct。两边都不挂 function
# → PC 枚举不到 MTP，系统只剩“仅充电”。因此把这两条门换成 property:vendor.usb.use_ffs_mtp=0，
# 与第一步的属性翻转配对；ptp/ptp,adb 本就无门，ramdump=enable 的小米工程分支保持不动。
declare -a rc_gate_old=(
	'on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:ro.boot.ramdump=disable'
	'on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:ro.boot.ramdump=disable'
)
declare -a rc_gate_new=(
	'on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=0'
	'on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=0'
)
usb_rc="$project_dir/system/system/etc/init/hw/init.usb.configfs.rc"
rc_gate_changed=0
rc_gate_skipped=0

if [[ -L "$usb_rc" ]]; then
	err_print "不支持直接修改符号链接：system/system/etc/init/hw/init.usb.configfs.rc"
	exit 1
elif [[ ! -e "$usb_rc" ]]; then
	warn_print "MTP 触发器目标不存在，跳过放开 ramdump 门：system/system/etc/init/hw/init.usb.configfs.rc"
elif [[ ! -f "$usb_rc" ]]; then
	err_print "MTP 触发器目标不是普通文件：system/system/etc/init/hw/init.usb.configfs.rc"
	exit 1
else
	# 先全量校验：要么已是目标形态，要么能找到待改的原始行；两者都找不到则失败，
	# 避免 HyperOS 版本变化后静默不生效。
	gate_index=0
	for old_trigger in "${rc_gate_old[@]}"; do
		new_trigger="${rc_gate_new[$gate_index]}"
		if grep -Fxq -- "$new_trigger" "$usb_rc"; then
			:
		elif ! grep -Fxq -- "$old_trigger" "$usb_rc"; then
			err_print "未找到预期的 MTP 触发器，不能确认 ramdump 门形态：$old_trigger"
			exit 1
		fi
		gate_index=$((gate_index + 1))
	done

	rc_temp="$(mktemp "${usb_rc}.gate.XXXXXX")"
	rc_gate_cleanup() {
		if [[ -n "${rc_temp:-}" ]]; then
			rm -f -- "$rc_temp"
		fi
		return 0
	}
	trap rc_gate_cleanup EXIT
	if ! awk -v old1="${rc_gate_old[0]}" -v new1="${rc_gate_new[0]}" \
		-v old2="${rc_gate_old[1]}" -v new2="${rc_gate_new[1]}" '
		{
			if ($0 == old1) { print new1; next }
			if ($0 == old2) { print new2; next }
			print
		}
	' "$usb_rc" > "$rc_temp"; then
		err_print "改写 init.usb.configfs.rc 的 MTP 触发器失败"
		exit 1
	fi
	for new_trigger in "${rc_gate_new[@]}"; do
		if ! grep -Fxq -- "$new_trigger" "$rc_temp"; then
			err_print "MTP 触发器改写后缺少预期条目：$new_trigger"
			exit 1
		fi
	done
	for old_trigger in "${rc_gate_old[@]}"; do
		if grep -Fxq -- "$old_trigger" "$rc_temp"; then
			err_print "MTP 触发器改写后仍残留 ramdump 门：$old_trigger"
			exit 1
		fi
	done
	if cmp -s -- "$rc_temp" "$usb_rc"; then
		rc_gate_skipped=1
	elif ! replace_file_if_different "$rc_temp" "$usb_rc"; then
		err_print "写回 init.usb.configfs.rc 失败"
		exit 1
	else
		rc_gate_changed=1
	fi
	rc_gate_cleanup
	trap - EXIT
fi

if (( rc_gate_changed == 1 )); then
	std_print "✅ 已把 mtp/mtp,adb 装配分支的 ro.boot.ramdump=disable 门改为 use_ffs_mtp=0（真机无该属性，原门永不成立）"
elif (( rc_gate_skipped == 1 )); then
	skip_print "init.usb.configfs.rc 的 mtp/mtp,adb 触发器已是目标形态"
fi

std_print "处理完成"
