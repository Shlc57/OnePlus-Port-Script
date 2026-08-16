#!/bin/bash
set -e

init_port_env "${1:-}"

std_print "禁用 ODM 外部 build.prop 导入"
std_print

check_part_exists odm

comment_odm_import() {
	local file_path=$1
	local import_regex=$2
	local import_name=$3

	if [ ! -f "$file_path" ]; then
		skip_print "未找到 ${file_path#$project_dir/}，跳过"
		return
	fi

	if grep -Eq "^[[:space:]]*import[[:space:]]+${import_regex}[[:space:]]*$" "$file_path"; then
		sed -i -E "s|^([[:space:]]*)(import[[:space:]]+${import_regex}[[:space:]]*)$|\\1#\\2|" "$file_path"
		std_print "已禁用 $import_name"
	else
		skip_print "$import_name 不存在或已禁用"
	fi
}

for build_prop in "$project_dir/odm/build.prop" "$project_dir/odm/etc/build.prop"; do
	comment_odm_import "$build_prop" '/odm/etc/\$\{ro\.boot\.prjname\}/build\.prop' 'import /odm/etc/${ro.boot.prjname}/build.prop'
	comment_odm_import "$build_prop" '/mnt/vendor/my_manifest/build\.prop' 'import /mnt/vendor/my_manifest/build.prop'
done

std_print "处理完成"
