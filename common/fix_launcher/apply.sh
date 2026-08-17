#!/bin/bash
set -e

init_port_env "${1:-}"

std_print "修复系统桌面启动配置"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
build_props=(
	"$project_dir/odm/build.prop"
	"$project_dir/odm/etc/build.prop"
)
available_build_props=()
for build_prop in "${build_props[@]}"; do
	if [[ -L "$build_prop" ]]; then
		err_print "不支持直接修改符号链接：$build_prop"
		exit 1
	elif [[ ! -e "$build_prop" ]]; then
		warn_print "属性目标不存在，跳过：${build_prop#"$project_dir"/}"
		continue
	elif [[ ! -f "$build_prop" ]]; then
		err_print "属性目标不是普通文件：$build_prop"
		exit 1
	fi
	available_build_props+=("$build_prop")
done

for build_prop in "${available_build_props[@]}"; do
	ensure_prop "$build_prop" ro.miui.region cn
	ensure_prop "$build_prop" ro.miui.product.home com.miui.home
	ensure_prop "$build_prop" ro.apex.updatable true
done

std_print "处理完成"
