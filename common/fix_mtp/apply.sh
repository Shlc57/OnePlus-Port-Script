#!/bin/bash
set -euo pipefail

patcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

init_port_env "${1:-}"

std_print "修复 MTP USB 配置"
std_print "使用  init.usb.configfs.rc 中的底包配置"
std_print

check_part_exists system

source_file="$patcher_dir/init.usb.configfs.rc"
target_file="$project_dir/system/system/etc/init/hw/init.usb.configfs.rc"
check_file_exists "$source_file" "底包 init.usb.configfs.rc（请放入 DNA_input）"
check_file_exists "$target_file"
if [[ -L "$source_file" || -L "$target_file" ]]; then
	err_print "MTP 配置源文件和目标文件都必须是普通文件"
	exit 1
fi

required_triggers=(
	'on property:sys.usb.config=mtp && property:sys.usb.configfs=1'
	'on property:sys.usb.config=mtp,adb && property:sys.usb.configfs=1'
)
for trigger in "${required_triggers[@]}"; do
	if ! grep -Fqx "$trigger" "$source_file"; then
		err_print "底包 init.usb.configfs.rc 缺少 MTP 触发器：$trigger"
		exit 1
	fi
done

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
