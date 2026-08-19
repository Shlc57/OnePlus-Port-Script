#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "启用 MI SurfaceFlinger LTPO 能力"
std_print "注意：仅开放上层 LTPO 策略，不补充面板、HWC 或 DynFPS 底层实现"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
odm_build_prop="$project_dir/odm/etc/build.prop"
if [[ -L "$odm_build_prop" ]]; then
	err_print "不支持直接修改符号链接：$odm_build_prop"
	exit 1
elif [[ ! -e "$odm_build_prop" ]]; then
	warn_print "LTPO 属性目标不存在，跳过：${odm_build_prop#"$project_dir"/}"
	std_print "处理完成"
	exit 0
elif [[ ! -f "$odm_build_prop" ]]; then
	err_print "LTPO 属性目标不是普通文件：$odm_build_prop"
	exit 1
fi

ensure_prop "$odm_build_prop" ro.vendor.mi_sf.ltpo.support true
std_print "✅ 已写入：ro.vendor.mi_sf.ltpo.support=true"
std_print "处理完成"
