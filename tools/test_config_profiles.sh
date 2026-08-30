#!/bin/bash
# 行为测试：配置目录检测、DNA_config/config 优先级与分区 metadata 文件名解析。
# 两套目录（DNA_config、config）与两套文件名模板（DNA 命名、旧版命名）可任意组合。
set -euo pipefail

tools_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tools.sh
source "$tools_dir/tools.sh"

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	exit 1
}

expect_path() {
	local actual="$1" expected="$2"
	[[ "$actual" == "$expected" ]] || fail "路径解析不符：期望 $expected，实际 $actual"
}

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

make_project() {
	mkdir -p "$1"
	printf 'project=%s\n' "$1"
}

# 用例 1：仅有 DNA_config（DNA 命名）。
project="$(make_project "$tmp/dna_only")"
mkdir -p "$project/DNA_config"
: >"$project/DNA_config/odm_contexts.txt"
: >"$project/DNA_config/odm_fsconfig.txt"
project_dir="$project"
expect_path "$(get_part_contexts_path odm)" "$project/DNA_config/odm_contexts.txt"
expect_path "$(get_part_fsconfig_path odm)" "$project/DNA_config/odm_fsconfig.txt"
[[ "$(get_part_contexts_name odm)" == "odm_contexts.txt" ]] || fail "contexts 名称解析错误"

# 用例 2：仅有 config（旧版命名）。
project="$(make_project "$tmp/config_only")"
mkdir -p "$project/config"
: >"$project/config/vendor_file_contexts"
: >"$project/config/vendor_fs_config"
project_dir="$project"
expect_path "$(get_part_contexts_path vendor)" "$project/config/vendor_file_contexts"
expect_path "$(get_part_fsconfig_path vendor)" "$project/config/vendor_fs_config"

# 用例 3：两目录同时存在 → DNA_config 优先。
project="$(make_project "$tmp/both_dirs")"
mkdir -p "$project/DNA_config" "$project/config"
: >"$project/DNA_config/product_contexts.txt"
: >"$project/DNA_config/product_fsconfig.txt"
: >"$project/config/product_file_contexts"
: >"$project/config/product_fs_config"
project_dir="$project"
expect_path "$(get_part_contexts_path product)" "$project/DNA_config/product_contexts.txt"
expect_path "$(get_part_fsconfig_path product)" "$project/DNA_config/product_fsconfig.txt"

# 用例 4：目录名与文件名模板混搭也能识别（不同解包工具产物混放）。
project="$(make_project "$tmp/mixed_naming")"
mkdir -p "$project/DNA_config" "$project/config"
: >"$project/DNA_config/system_file_contexts"      # DNA 目录 + 旧版命名
: >"$project/DNA_config/system_fs_config"
: >"$project/config/system_ext_contexts.txt"       # config 目录 + DNA 命名
: >"$project/config/system_ext_fsconfig.txt"
project_dir="$project"
expect_path "$(get_part_contexts_path system)" "$project/DNA_config/system_file_contexts"
expect_path "$(get_part_fsconfig_path system)" "$project/DNA_config/system_fs_config"
expect_path "$(get_part_contexts_path system_ext)" "$project/config/system_ext_contexts.txt"
expect_path "$(get_part_fsconfig_path system_ext)" "$project/config/system_ext_fsconfig.txt"

# 用例 5：同一分区两套命名并存于同一目录 → 模板顺序决定（DNA 命名优先）。
project="$(make_project "$tmp/dual_naming_one_dir")"
mkdir -p "$project/config"
: >"$project/config/mi_ext_file_contexts"
: >"$project/config/mi_ext_contexts.txt"
project_dir="$project"
expect_path "$(get_part_contexts_path mi_ext)" "$project/config/mi_ext_contexts.txt"

# 用例 6：目录存在但分区文件全缺 → 回退到首个配置目录自身模板（由调用方报缺失）。
project="$(make_project "$tmp/missing_part")"
mkdir -p "$project/config"
project_dir="$project"
expect_path "$(get_part_contexts_path product)" "$project/config/product_file_contexts"
[[ ! -e "$(get_part_contexts_path product)" ]] || fail "缺失文件不应被创建"

# 用例 7：完全没有任何配置目录 → 报错。
project="$(make_project "$tmp/no_config")"
project_dir="$project"
if get_part_contexts_path odm >/dev/null 2>&1; then
	fail "缺少配置目录时应解析失败"
fi

# 用例 8：init_port_env 在两种目录形态下都能初始化。
project="$(make_project "$tmp/init_dna")"
mkdir -p "$project/DNA_config"
init_port_env "$project" >/dev/null
[[ "$config_profile" == "DNA_config" ]] || fail "init_port_env 未选中 DNA_config"
project="$(make_project "$tmp/init_config")"
mkdir -p "$project/config"
init_port_env "$project" >/dev/null
[[ "$config_profile" == "config" ]] || fail "init_port_env 未选中 config"

printf '配置目录与文件名解析行为测试通过\n'
