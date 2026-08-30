#!/bin/bash
set -euo pipefail

# devices/oneplus_ace6/fix_vendor_selinux_files/apply.sh
# Ace 6 vendor SELinux 基础设施文件补齐补丁。
# 背景：Ace 6 底包 vendor 分区缺 genfs_labels_version.txt / plat_sepolicy_vers.txt，
#       common/fix_vendor_avc 的 check_file_exists 会直接 FAIL。
# 方案：两个版本号文件已实测固化并**内置**在本模块（202504，与原包 mi_vendor
#       SELinux 版本标记一致），不再从外部工程目录提取。
# 注意：
#   - plat_sepolicy_vers 与 genfs_labels_version 必须同值（202504）：
#     genfs 版本须与底包 vendor_sepolicy.cil 的基线一致，否则 init 用错误的
#     genfs 版本解析 policy 会启动失败（实测 Ace 6 DSU 一屏后 fastboot）。
#   - 补齐后底包与原包版本标记一致，common/fix_vendor_avc 的
#     --allow-version-mismatch 跨 ABI 降级分支在此机型上不再触发（保留作保险）。
#   - 6T 底包不缺这两个文件，无需加入 Ace 6T 流程；误加时文件已存在自动跳过。

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "Ace 6 vendor SELinux 基础设施文件补齐（写入内置版本号 202504）"
std_print

check_part_exists vendor

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
vendor_selinux="$project_dir/vendor/etc/selinux"
if [[ ! -d "$vendor_selinux" || -L "$vendor_selinux" ]]; then
	err_print "底包 vendor SELinux 目录不存在或不是普通目录：$vendor_selinux（底包 vendor 未解包？）"
	exit 1
fi

temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

# 文件不存在时写入内置版本号（本来就要新增的文件）；已存在时跳过，
# 不覆盖底包或前次补丁的值。
write_version_file() {
	local target_file="$1"
	local expected_content="$2"
	local display_name
	local temporary_file
	local current_content

	display_name="${target_file#"$vendor_selinux"/}"
	if [[ -L "$target_file" ]]; then
		err_print "SELinux 版本标记文件不能是符号链接：$target_file"
		exit 1
	fi
	if [[ -e "$target_file" ]]; then
		if [[ ! -f "$target_file" ]]; then
			err_print "SELinux 版本标记目标不是普通文件：$target_file"
			exit 1
		fi
		current_content="$(tr -d '[:space:]' < "$target_file")"
		if [[ -z "$current_content" ]]; then
			err_print "SELinux 版本标记文件存在但为空：$target_file"
			exit 1
		fi
		std_print "已存在: vendor/etc/selinux/${display_name}（当前值 ${current_content}），跳过"
		return 0
	fi
	temporary_file="$(mktemp "${target_file}.tmp.XXXXXX")"
	temporary_files+=("$temporary_file")
	printf '%s\n' "$expected_content" > "$temporary_file"
	chmod 0644 -- "$temporary_file"
	mv -f -- "$temporary_file" "$target_file"
	std_print "✅ 已写入: vendor/etc/selinux/${display_name}（内容 ${expected_content}）"
}

write_version_file "$vendor_selinux/plat_sepolicy_vers.txt" '202504'
write_version_file "$vendor_selinux/genfs_labels_version.txt" '202504'

# 两个版本标记必须同值，否则 init 解析 vendor policy 时 genfs 基线错位。
plat_vers="$(tr -d '[:space:]' < "$vendor_selinux/plat_sepolicy_vers.txt")"
genfs_vers="$(tr -d '[:space:]' < "$vendor_selinux/genfs_labels_version.txt")"
if [[ ! "$plat_vers" =~ ^[0-9]+$ || ! "$genfs_vers" =~ ^[0-9]+$ ]]; then
	err_print "SELinux 版本标记应为纯数字（plat=${plat_vers} / genfs=${genfs_vers}）"
	exit 1
fi
if [[ "$plat_vers" != "$genfs_vers" ]]; then
	err_print "plat_sepolicy_vers（${plat_vers}）与 genfs_labels_version（${genfs_vers}）不同值，init 解析 policy 会启动失败"
	exit 1
fi

std_print "✅ vendor SELinux 版本标记就绪：plat_sepolicy_vers=${plat_vers}，genfs_labels_version=${genfs_vers}"
std_print "处理完成"
