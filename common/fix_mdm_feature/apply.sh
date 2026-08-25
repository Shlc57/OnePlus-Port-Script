#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复 mdm_feature 的 SVN/OTA property contexts"
std_print "只恢复原包已有的 exported_default_prop 标签，不新增宽泛 SELinux allow"
std_print

check_part_exists odm
check_partition_metadata_tool >/dev/null

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
odm_selinux_dir="$project_dir/odm/etc/selinux"
odm_property_contexts="$odm_selinux_dir/odm_property_contexts"
odm_metadata_contexts="$(get_part_contexts_path odm)"
odm_metadata_fsconfig="$(get_part_fsconfig_path odm)"
property_context_fragment="$patcher_dir/config/odm_property_contexts"
metadata_context_fragment="$patcher_dir/config/odm_metadata_contexts"
metadata_fsconfig_fragment="$patcher_dir/config/odm_fsconfig"

for required_file in \
	"$property_context_fragment" \
	"$metadata_context_fragment" \
	"$metadata_fsconfig_fragment" \
	"$odm_metadata_contexts" \
	"$odm_metadata_fsconfig"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "mdm_feature 输入不能是符号链接：$required_file"
		exit 1
	fi
done

if [[ -L "$odm_selinux_dir" || ! -d "$odm_selinux_dir" ]]; then
	err_print "ODM SELinux 目录不存在或不是普通目录：$odm_selinux_dir"
	exit 1
fi
if [[ -L "$odm_property_contexts" ]]; then
	err_print "ODM property contexts 不能是符号链接：$odm_property_contexts"
	exit 1
elif [[ -e "$odm_property_contexts" && ! -f "$odm_property_contexts" ]]; then
	err_print "ODM property contexts 不是普通文件：$odm_property_contexts"
	exit 1
fi

expected_property_contexts=(
	'ro.build.version.svn.c u:object_r:exported_default_prop:s0'
	'ro.build.version.svn u:object_r:exported_default_prop:s0'
	'ro.build.version.ota u:object_r:exported_default_prop:s0'
)
property_context_entry_count=0
while IFS=$' \t' read -r context_key context_value extra_field || \
	[[ -n "$context_key" || -n "$context_value" ]]; do
	context_key="${context_key%$'\r'}"
	context_value="${context_value%$'\r'}"
	extra_field="${extra_field%$'\r'}"
	[[ -z "$context_key" || "$context_key" == \#* ]] && continue
	if [[ -n "$extra_field" ]]; then
		err_print "mdm_feature property contexts 片段字段过多：$property_context_fragment"
		exit 1
	fi
	if ! printf '%s\n' "${expected_property_contexts[@]}" | \
		grep -Fqx "$context_key $context_value"; then
		err_print "mdm_feature property contexts 片段包含未声明条目：$context_key $context_value"
		exit 1
	fi
	property_context_entry_count=$((property_context_entry_count + 1))
done < "$property_context_fragment"
if (( property_context_entry_count != ${#expected_property_contexts[@]} )); then
	err_print "mdm_feature property contexts 片段条目数不正确：$property_context_fragment"
	exit 1
fi

if ! grep -Fqx \
	'/odm/etc/selinux/odm_property_contexts u:object_r:property_contexts_file:s0' \
	"$metadata_context_fragment" || \
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$metadata_context_fragment") != 1 )); then
	err_print "mdm_feature ODM contexts 片段不完整"
	exit 1
fi
if ! grep -Fqx \
	'odm/etc/selinux/odm_property_contexts 0 0 0644' \
	"$metadata_fsconfig_fragment" || \
	(( $(grep -Ec '^[[:space:]]*[^#[:space:]]' "$metadata_fsconfig_fragment") != 1 )); then
	err_print "mdm_feature ODM fsconfig 片段不完整"
	exit 1
fi

temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

temporary_property_contexts="$(mktemp "$(get_config_path '.fix_mdm_feature_property_contexts.XXXXXX')")"
temporary_odm_contexts="$(mktemp "$(get_config_path '.fix_mdm_feature_odm_contexts.XXXXXX')")"
temporary_odm_fsconfig="$(mktemp "$(get_config_path '.fix_mdm_feature_odm_fsconfig.XXXXXX')")"
temporary_files+=(
	"$temporary_property_contexts"
	"$temporary_odm_contexts"
	"$temporary_odm_fsconfig"
)

# 保留已有 ODM property contexts（例如 LTPO 的 ADFR 条目），只按路径覆盖
# mdm_feature 所需的三个精确属性。目标不存在时才创建最小新文件。
if [[ -e "$odm_property_contexts" ]]; then
	cp -p -- "$odm_property_contexts" "$temporary_property_contexts"
	merge_contexts_file "$property_context_fragment" "$temporary_property_contexts"
else
	cp -p -- "$property_context_fragment" "$temporary_property_contexts"
	chmod 0644 -- "$temporary_property_contexts"
fi

for expected_context in "${expected_property_contexts[@]}"; do
	expected_key="${expected_context%% *}"
	expected_value="${expected_context#* }"
	if (( $(awk -v key="$expected_key" '$1 == key { count++ } END { print count + 0 }' \
		"$temporary_property_contexts") != 1 )) || \
		! awk -v key="$expected_key" -v value="$expected_value" \
		'$1 == key && $2 == value { found = 1 } END { exit found ? 0 : 1 }' \
		"$temporary_property_contexts"; then
		err_print "生成的 ODM property contexts 缺少唯一正确条目：$expected_key"
		exit 1
	fi
done

cp -p -- "$odm_metadata_contexts" "$temporary_odm_contexts"
cp -p -- "$odm_metadata_fsconfig" "$temporary_odm_fsconfig"
merge_contexts_file "$metadata_context_fragment" "$temporary_odm_contexts"
merge_fsconfig_file "$metadata_fsconfig_fragment" "$temporary_odm_fsconfig"

if ! grep -Fqx \
	'/odm/etc/selinux/odm_property_contexts u:object_r:property_contexts_file:s0' \
	"$temporary_odm_contexts" || \
	! grep -Fqx \
	'odm/etc/selinux/odm_property_contexts 0 0 0644' \
	"$temporary_odm_fsconfig"; then
	err_print "生成的 ODM property contexts metadata 不完整"
	exit 1
fi

_install_generated_file "$temporary_odm_contexts" "$odm_metadata_contexts"
_install_generated_file "$temporary_odm_fsconfig" "$odm_metadata_fsconfig"
if [[ -e "$odm_property_contexts" ]]; then
	_install_generated_file "$temporary_property_contexts" "$odm_property_contexts"
else
	replace_file_if_different "$temporary_property_contexts" "$odm_property_contexts"
fi

std_print "✅ 已恢复 ro.build.version.svn.c、ro.build.version.svn、ro.build.version.ota 标签"
std_print "ℹ️ 不写入属性值；SVN/OTA 实际值仍由底包属性来源提供"
std_print "处理完成"
