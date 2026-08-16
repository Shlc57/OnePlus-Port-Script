#!/bin/bash
set -uo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=tools.sh
source "$script_dir/tools.sh"

print_help() {
	cat <<'EOF'
用法：
  bash auto_port.sh
  bash auto_port.sh list
  bash auto_port.sh help
  bash auto_port.sh [--project-dir 项目目录] 补丁路径 [补丁路径 ...]

补丁路径示例：
  common/fix_launcher
  devices/oneplus15/fix_auto_brightness

未指定补丁时仅列出可用补丁。只有显式传入的补丁才会按参数顺序执行。
为兼容旧用法，也可传入不含分类路径的补丁名；该名称必须全局唯一。
apply.sh 由本脚本在隔离子 Shell 中加载，不应直接执行。
EOF
}

discover_modules() {
	{
		if [[ -d "$script_dir/common" ]]; then
			find "$script_dir/common" \
				-mindepth 2 -maxdepth 2 -type f -name apply.sh -print
		fi
		if [[ -d "$script_dir/devices" ]]; then
			find "$script_dir/devices" \
				-mindepth 3 -maxdepth 3 -type f -name apply.sh -print
		fi
	} | LC_ALL=C sort
}

declare -a available_module_paths=()
declare -a available_apply_scripts=()

load_modules() {
	local apply_script
	local module_dir

	available_module_paths=()
	available_apply_scripts=()
	while IFS= read -r apply_script; do
		module_dir="$(dirname -- "$apply_script")"
		available_module_paths+=("${module_dir#"$script_dir"/}")
		available_apply_scripts+=("$apply_script")
	done < <(discover_modules)
}

list_modules() {
	local index
	local found_common=0
	local found_device=0

	load_modules
	std_print "通用补丁："
	for index in "${!available_module_paths[@]}"; do
		if [[ "${available_module_paths[$index]}" == common/* ]]; then
			printf '  %s\n' "${available_module_paths[$index]}"
			found_common=1
		fi
	done
	if (( found_common == 0 )); then
		skip_print "未发现通用补丁"
	fi

	std_print "设备专属补丁："
	for index in "${!available_module_paths[@]}"; do
		if [[ "${available_module_paths[$index]}" == devices/* ]]; then
			printf '  %s\n' "${available_module_paths[$index]}"
			found_device=1
		fi
	done
	if (( found_device == 0 )); then
		skip_print "未发现设备专属补丁"
	fi
}

resolve_module() {
	local requested_module="${1:-}"
	local index
	local module_basename
	local -a matched_indexes=()

	resolved_module_path=""
	resolved_apply_script=""
	if ! _is_safe_relative_path "$requested_module"; then
		err_print "无效的补丁路径：$requested_module"
		return 1
	fi

	for index in "${!available_module_paths[@]}"; do
		if [[ "$requested_module" == */* ]]; then
			if [[ "${available_module_paths[$index]}" == "$requested_module" ]]; then
				matched_indexes+=("$index")
			fi
		else
			module_basename="$(basename -- "${available_module_paths[$index]}")"
			if [[ "$module_basename" == "$requested_module" ]]; then
				matched_indexes+=("$index")
			fi
		fi
	done

	case "${#matched_indexes[@]}" in
		0)
			err_print "补丁不存在：$requested_module"
			return 1
			;;
		1)
			index="${matched_indexes[0]}"
			resolved_module_path="${available_module_paths[$index]}"
			resolved_apply_script="${available_apply_scripts[$index]}"
			;;
		*)
			err_print "补丁名不唯一，请使用完整分类路径：$requested_module"
			for index in "${matched_indexes[@]}"; do
				err_print "  ${available_module_paths[$index]}"
			done
			return 1
			;;
	esac
}

load_modules
if (( ${#available_module_paths[@]} == 0 )); then
	err_print "未发现任何补丁"
	exit 1
fi

requested_project_dir=""
declare -a requested_modules=()

while (( $# > 0 )); do
	case "$1" in
		-p|--project-dir)
			if (( $# < 2 )); then
				err_print "$1 缺少项目目录参数"
				exit 1
			fi
			requested_project_dir="$2"
			shift 2
			;;
		--project-dir=*)
			requested_project_dir="${1#*=}"
			shift
			;;
		-h|--help|help)
			if (( ${#requested_modules[@]} > 0 )); then
				err_print "help 不能与补丁同时使用"
				exit 1
			fi
			print_help
			exit 0
			;;
		-l|--list|list)
			if (( ${#requested_modules[@]} > 0 )); then
				err_print "list 不能与补丁同时使用"
				exit 1
			fi
			list_modules
			exit 0
			;;
		--)
			shift
			while (( $# > 0 )); do
				requested_modules+=("$1")
				shift
			done
			;;
		-*)
			err_print "未知选项：$1"
			exit 1
			;;
		*)
			requested_modules+=("$1")
			shift
			;;
	esac
done

if (( ${#requested_modules[@]} == 0 )); then
	list_modules
	exit 0
fi

init_port_env "$requested_project_dir" || exit 1

for requested_module in "${requested_modules[@]}"; do
	resolve_module "$requested_module" || exit 1
	std_print "APPLY: $resolved_module_path"
	(
		# 模拟独立 bash 脚本的默认选项，再由 apply.sh 自行启用所需严格模式。
		set +e
		set +u
		set +o pipefail
		set -- "$project_dir"
		# shellcheck disable=SC1090
		source "$resolved_apply_script"
	)
	apply_status=$?
	if (( apply_status != 0 )); then
		err_print "FAIL: $resolved_module_path"
		exit 1
	fi
done
