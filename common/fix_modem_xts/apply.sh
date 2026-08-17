#!/usr/bin/env bash
set -Eeuo pipefail

patcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

init_port_env "${1:-}"

std_print "修复一加 15 基带不兼容的小米 OEM Hook"
std_print "保留小米 qcrilmsgtunnel，跳过 XTS 版本查询与屏幕状态通知"
check_part_exists system
check_file_exists "$(get_part_contexts_path system)"
check_file_exists "$(get_part_fsconfig_path system)"
check_partition_metadata_tool >/dev/null

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
teleservice_dir="$project_dir/system/system/priv-app/TeleService"
teleservice_apk="$teleservice_dir/TeleService.apk"
oat_dir="$teleservice_dir/oat"

if [[ ! -f "$teleservice_apk" ]]; then
	err_print "找不到 TeleService.apk：$teleservice_apk"
	exit 1
fi

bash "$patcher_dir/patch_apk.sh" "$teleservice_apk"

remove_path_if_exists "$oat_dir"
remove_part_metadata_prefix system system/priv-app/TeleService/oat

std_print "处理完成"
