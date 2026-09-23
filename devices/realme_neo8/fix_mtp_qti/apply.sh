#!/bin/bash
set -euo pipefail

# devices/realme_neo8/fix_mtp_qti/apply.sh
# 真我 Neo8 Qti MTP 适配（与 common/fix_mtp 机制不同，见 README 拆分理由）。
# 根因（纯底包分区取证）：
#   - Neo8 底包 vendor/build.prop: vendor.usb.use_ffs_mtp=1、use_gadget_hal=0，
#     MTP 组合由底包 vendor init.qcom.usb.rc 在 config=mtp/ptp && configfs=1 时
#     挂 ffs.mtp（functionfs，第 1921/1934/1949/1964 行），需消费 /dev/usb-ffs/mtp
#     的 Oplus MTP 守护。
#   - 移植 system 用小米原包 init.usb.configfs.rc，同一属性走 kernel mtp.gs0。
#     经逐字比对，realme 原厂 system init.usb.configfs.rc 与小米原包该文件的
#     mtp/ptp/gadget 关键行完全一致 —— 所以 common/fix_mtp（换 system rc）对 Neo8
#     是 no-op，不能沿用；真正分歧在 ffs.mtp vs mtp.gs0。
#   - HyperOS 框架与其自带 system rc 都按 kernel mtp.gs0 驱动 MTP，不对接 Oplus
#     ffs.mtp 契约，双触发下 f1 落到 ffs.mtp 且无人消费 → MTP 不可用。
# 修法（最小侵入）：把 vendor.usb.use_ffs_mtp 置 0，令底包 vendor 的 ffs.mtp 挂接
#   与 zygote functionfs 挂载（条件 =1）都不再触发，kernel mtp.gs0 成为唯一组合，
#   与 HyperOS 框架一致。仅改 vendor/build.prop 内容，不改路径/属主/权限，无需动
#   contexts/fsconfig。该属性全树仅 vendor/build.prop 定义一处，无脚本动态改写。
# 边界：本修复只针对纯 mtp/mtp,adb/ptp/ptp,adb（厂商 diag/rmnet 组合本就有
#   use_ffs_mtp=0 的 mtp.gs0 分支，不受影响）。仍需真机确认枚举与文件读写；未在
#   真实设备验证前不得记为已生效。

init_port_env "${1:-}"

std_print "修复 Neo8 Qti MTP：vendor.usb.use_ffs_mtp 置 0，统一走 kernel mtp.gs0"
std_print

check_part_exists vendor

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
vendor_build_prop="$project_dir/vendor/build.prop"

prop_key='vendor.usb.use_ffs_mtp'
prop_value='0'

# 属性目标缺失时按可选 prop 子步骤处理：warn 并跳过，不失败整条补丁。
if [[ -L "$vendor_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$vendor_build_prop"
	exit 1
elif [[ ! -e "$vendor_build_prop" ]]; then
	warn_print "vendor build.prop 不存在，跳过 MTP 属性适配：${vendor_build_prop#"$project_dir"/}"
	std_print "处理完成"
	exit 0
elif [[ ! -f "$vendor_build_prop" ]]; then
	err_print "vendor build.prop 不是普通文件：$vendor_build_prop"
	exit 1
fi

current_value="$(read_prop_value "$prop_key" "$vendor_build_prop" 2>/dev/null)" || current_value=''
if [[ "$current_value" == "$prop_value" ]]; then
	skip_print "${prop_key} 已是 ${prop_value}，跳过"
	std_print "处理完成"
	exit 0
fi

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

std_print "✅ 已置 ${prop_key}=${prop_value}（原值 ${current_value:-<未设置>}）：MTP 组合回退到 kernel mtp.gs0，与 HyperOS 框架一致"
std_print "处理完成"
