#!/usr/bin/env bash
set -Eeuo pipefail

patcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

init_port_env "${1:-}"

std_print "修复 Settings 触感支持"
check_part_exists system_ext

settings_dir="$project_dir/system_ext/priv-app/Settings"
settings_apk="$settings_dir/Settings.apk"
oat_dir="$settings_dir/oat"

if [[ ! -f "$settings_apk" ]]; then
    err_print "找不到 Settings.apk：$settings_apk"
    exit 1
fi

bash "$patcher_dir/patch_apk.sh" "$settings_apk"

remove_path_if_exists "$oat_dir"

std_print "处理完成"
