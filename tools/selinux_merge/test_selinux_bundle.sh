#!/bin/bash
set -euo pipefail

test_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port_dir="$(cd -- "$test_dir/../.." && pwd -P)"
# shellcheck source=../tools.sh
# shellcheck disable=SC1091 # 动态解析仓库根目录，单文件 ShellCheck 不跟随该来源。
source "$port_dir/tools/tools.sh"

temporary_root="$(mktemp -d)"
cleanup() {
	rm -rf -- "$temporary_root"
}
trap cleanup EXIT

bundle_dir="$temporary_root/bundle"
project_root="$temporary_root/project"
mkdir -p -- "$bundle_dir/config" "$project_root/odm/bin"
printf '(type test_domain)\n' > "$bundle_dir/config/policy.cil"
printf '/odm/bin/test u:object_r:test_exec:s0\n' > "$bundle_dir/config/file_contexts"
printf '%s\t%s\t%s\n' \
	'require' 'project' 'odm/bin/test' \
	'require' 'project' 'odm/bin/test-helper' \
	'policy' 'vendor_policy' 'config/policy.cil' \
	'contexts' 'vendor_file_contexts' 'config/file_contexts' \
	> "$bundle_dir/selinux_bundle.tsv"

load_selinux_bundle_manifest "$bundle_dir/selinux_bundle.tsv" "$bundle_dir"
(( ${#SELINUX_BUNDLE_REQUIREMENTS[@]} == 2 ))
(( ${#SELINUX_BUNDLE_POLICY_FRAGMENTS[@]} == 1 ))
(( ${#SELINUX_BUNDLE_CONTEXT_TARGETS[@]} == 1 ))
[[ "${SELINUX_BUNDLE_CONTEXT_TARGETS[0]}" == vendor_file_contexts ]]

check_selinux_bundle_requirements "$project_root"
[[ "$SELINUX_BUNDLE_ACTIVE" == false ]]

printf 'test\n' > "$project_root/odm/bin/test"
if check_selinux_bundle_requirements "$project_root" 2>/dev/null; then
	printf 'partial SELinux bundle was accepted\n' >&2
	exit 1
fi

printf 'helper\n' > "$project_root/odm/bin/test-helper"
check_selinux_bundle_requirements "$project_root"
[[ "$SELINUX_BUNDLE_ACTIVE" == true ]]

rm -f -- "$project_root/odm/bin/test-helper"
ln -s -- test "$project_root/odm/bin/test-helper"
if check_selinux_bundle_requirements "$project_root" 2>/dev/null; then
	printf 'symlink SELinux bundle requirement was accepted\n' >&2
	exit 1
fi
rm -f -- "$project_root/odm/bin/test-helper"

printf '%s\t%s\t%s\n' \
	'require' 'project' 'odm/bin/test' \
	'contexts' 'unknown-target' 'config/file_contexts' \
	> "$bundle_dir/invalid.tsv"
if load_selinux_bundle_manifest "$bundle_dir/invalid.tsv" "$bundle_dir" 2>/dev/null; then
	printf 'invalid SELinux bundle target was accepted\n' >&2
	exit 1
fi

printf '%s\t%s\t%s\n' \
	'require' 'project' '../outside' \
	'policy' 'vendor_policy' 'config/policy.cil' \
	> "$bundle_dir/traversal.tsv"
if load_selinux_bundle_manifest "$bundle_dir/traversal.tsv" "$bundle_dir" 2>/dev/null; then
	printf 'SELinux bundle traversal was accepted\n' >&2
	exit 1
fi

printf 'selinux_bundle tests passed\n'
