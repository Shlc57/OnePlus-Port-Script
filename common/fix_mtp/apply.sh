#!/bin/bash
set -euo pipefail

patcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

init_port_env "${1:-}"

std_print "修复 MTP USB 配置"
std_print "使用  init.usb.configfs.rc 中的底包配置"
std_print

check_part_exists system

# 默认使用模块内置的一加 15 底包 rc；其他底包由组合入口通过
# FIX_MTP_SOURCE_RC 提供本机型来源，缺失或类型错误时失败。
source_file="$patcher_dir/init.usb.configfs.rc"
if [[ -n "${FIX_MTP_SOURCE_RC:-}" ]]; then
	source_file="${FIX_MTP_SOURCE_RC}"
fi
# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
target_file="$project_dir/system/system/etc/init/hw/init.usb.configfs.rc"
check_file_exists "$source_file" "底包 init.usb.configfs.rc（请放入 DNA_input）"
if [[ -L "$source_file" ]]; then
	err_print "MTP 配置源文件必须是普通文件：$source_file"
	exit 1
fi

required_triggers=(
	'on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=0'
	'on property:sys.usb.config=mtp && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=1'
	'on property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1'
	'on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=0'
	'on property:sys.usb.ffs.ready=1 && property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1 && property:vendor.usb.use_ffs_mtp=1'
)
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
