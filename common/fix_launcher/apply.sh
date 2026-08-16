#!/bin/bash
set -e

init_port_env "${1:-}"

std_print "修复系统桌面启动配置"
std_print

check_part_exists odm

build_props=(
	"$project_dir/odm/build.prop"
	"$project_dir/odm/etc/build.prop"
)
for build_prop in "${build_props[@]}"; do
	check_file_exists "$build_prop"
done

for build_prop in "${build_props[@]}"; do
	ensure_prop "$build_prop" ro.miui.region cn
	ensure_prop "$build_prop" ro.miui.product.home com.miui.home
	ensure_prop "$build_prop" ro.apex.updatable true
done

std_print "处理完成"
