#!/bin/bash
set -e

init_port_env "${1:-}"

std_print "禁用 ODM 外部 build.prop 导入"
std_print

comment_odm_import() {
	local file_path=$1
	local import_regex=$2
	local import_name=$3

	if [[ -L "$file_path" ]]; then
		err_print "不支持直接修改符号链接：$file_path"
		return 1
	elif [[ ! -e "$file_path" ]]; then
		warn_print "属性目标不存在，跳过：${file_path#"$project_dir"/}"
		return
	elif [[ ! -f "$file_path" ]]; then
		err_print "属性目标不是普通文件：$file_path"
		return 1
	fi

	if grep -Eq "^[[:space:]]*import[[:space:]]+${import_regex}[[:space:]]*$" "$file_path"; then
		sed -i -E "s|^([[:space:]]*)(import[[:space:]]+${import_regex}[[:space:]]*)$|\\1#\\2|" "$file_path"
		std_print "已禁用 $import_name"
	elif grep -Eq "^[[:space:]]*#[[:space:]]*import[[:space:]]+${import_regex}[[:space:]]*$" "$file_path"; then
		skip_print "$import_name 已禁用"
	else
		warn_print "属性导入不存在，跳过：${file_path#"$project_dir"/} 中的 $import_name"
	fi
}

for build_prop in "$project_dir/odm/build.prop" "$project_dir/odm/etc/build.prop"; do
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
	# 属性名中的 ${...} 是 build.prop 的字面量，不由当前 Shell 展开。
	# shellcheck disable=SC2016
	comment_odm_import "$build_prop" '/odm/etc/\$\{ro\.boot\.prjname\}/build\.prop' 'import /odm/etc/${ro.boot.prjname}/build.prop'
	comment_odm_import "$build_prop" '/mnt/vendor/my_manifest/build\.prop' 'import /mnt/vendor/my_manifest/build.prop'
done

std_print "处理完成"
