#!/usr/bin/env bash
set -Eeuo pipefail

patcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

init_port_env "${1:-}"

std_print "修复 Settings 触感支持"
check_part_exists system_ext

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
settings_dir="$project_dir/system_ext/priv-app/Settings"
settings_apk="$settings_dir/Settings.apk"
oat_dir="$settings_dir/oat"

if [[ -L "$settings_apk" ]]; then
	err_print "不支持修改符号链接 APK：$settings_apk"
	exit 1
elif [[ ! -e "$settings_apk" ]]; then
	warn_print "待修补的 Settings.apk 不存在，跳过：${settings_apk#"$project_dir"/}"
	std_print "处理完成"
	exit 0
elif [[ ! -f "$settings_apk" ]]; then
	err_print "待修补的 Settings.apk 不是普通文件：$settings_apk"
	exit 1
fi

check_file_exists "$(get_part_contexts_path system_ext)"
check_file_exists "$(get_part_fsconfig_path system_ext)"
check_partition_metadata_tool >/dev/null

remove_path_if_exists "$oat_dir"
remove_part_metadata_prefix system_ext priv-app/Settings/oat

bash "$patcher_dir/patch_apk.sh" "$settings_apk"

std_print "处理完成"
