#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "接入 Millet 核心桥、init.rc 和项目 SELinux bundle"
std_print

kmi="${KMI:-}"
if [[ -z "$kmi" || "$kmi" == "." || "$kmi" == ".." ||
	! "$kmi" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
	err_print "请通过 KMI 选择仓库内预编译 KMI"
	exit 1
fi

# shellcheck disable=SC2154 # project_dir is exported by init_port_env/tools.sh.
for part_name in system_ext vendor; do
	check_part_exists "$part_name"
	if [[ -L "$project_dir/$part_name" ]]; then
		err_print "Millet 目标分区不能是符号链接：$project_dir/$part_name"
		exit 1
	fi
done

prebuilt="$patcher_dir/prebuilt/$kmi/millet_core.ko"
init_source="$patcher_dir/config/init.millet_core.rc"
bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
policy_fragment="$patcher_dir/config/selinux_policy.cil.in"
system_ext_contexts_source="$patcher_dir/config/system_ext_contexts"
system_ext_fsconfig_source="$patcher_dir/config/system_ext_fsconfig"
vendor_contexts_source="$patcher_dir/config/vendor_contexts"
vendor_fsconfig_source="$patcher_dir/config/vendor_fsconfig"
system_ext_contexts="$(get_part_contexts_path system_ext)"
system_ext_fsconfig="$(get_part_fsconfig_path system_ext)"
vendor_contexts="$(get_part_contexts_path vendor)"
vendor_fsconfig="$(get_part_fsconfig_path vendor)"

for required_file in \
	"$prebuilt" \
	"$init_source" \
	"$bundle_manifest" \
	"$policy_fragment" \
	"$system_ext_contexts_source" \
	"$system_ext_fsconfig_source" \
	"$vendor_contexts_source" \
	"$vendor_fsconfig_source" \
	"$system_ext_contexts" \
	"$system_ext_fsconfig" \
	"$vendor_contexts" \
	"$vendor_fsconfig"; do
	if [[ ! -f "$required_file" || -L "$required_file" ]]; then
		err_print "Millet 补丁输入不存在或不是普通文件：$required_file"
		exit 1
	fi
done

for init_parent in \
	"$project_dir/vendor/etc" \
	"$project_dir/vendor/etc/init"; do
	if [[ ! -d "$init_parent" || -L "$init_parent" ]]; then
		err_print "Millet init.rc 目标目录不存在或不是普通目录：$init_parent"
		exit 1
	fi
done

# shellcheck disable=SC2154 # project_dir is exported by init_port_env/tools.sh.
ko_target="$project_dir/system_ext/lib64/modules/millet_core.ko"
init_target="$project_dir/vendor/etc/init/init.millet_core.rc"

# The standard /system/lib64/modules and /vendor/lib64/modules locations are
# backed by immutable DLKM partitions. Keep this feature on the ordinary
# system_ext tree and reject an accidental symlink at any path component
# before creating the module destination.
for module_dir in \
	"$project_dir/system_ext" \
	"$project_dir/system_ext/lib64" \
	"$project_dir/system_ext/lib64/modules"; do
	if [[ -L "$module_dir" || ( -e "$module_dir" && ! -d "$module_dir" ) ]]; then
		err_print "Millet KO 目标目录不是可写的普通目录：$module_dir"
		exit 1
	fi
done
if [[ -L "$ko_target" ]]; then
	err_print "Millet KO 目标不能是符号链接：$ko_target"
	exit 1
fi
if [[ -L "$init_target" ]]; then
	err_print "Millet init.rc 目标不能是符号链接：$init_target"
	exit 1
fi
replace_file_if_different "$prebuilt" "$ko_target"
replace_file_if_different "$init_source" "$init_target"

merge_contexts_file "$system_ext_contexts_source" "$system_ext_contexts"
merge_fsconfig_file "$system_ext_fsconfig_source" "$system_ext_fsconfig"
merge_contexts_file "$vendor_contexts_source" "$vendor_contexts"
merge_fsconfig_file "$vendor_fsconfig_source" "$vendor_fsconfig"

# The common SELinux entry consumes this registration after the files exist.
load_selinux_bundle_manifest "$bundle_manifest" "$patcher_dir"
if (( ${#SELINUX_BUNDLE_POLICY_FRAGMENTS[@]} != 1 )); then
	err_print "Millet SELinux bundle policy 片段缺失"
	exit 1
fi

std_print "Millet 核心桥已安装（KMI：$kmi）；SELinux bundle 已登记"
