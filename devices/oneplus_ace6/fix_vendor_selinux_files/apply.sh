#!/bin/bash
set -euo pipefail

# devices/oneplus_ace6/fix_vendor_selinux_files/apply.sh
# Ace 6 vendor SELinux 基础设施文件补齐补丁。
# 背景：Ace 6 底包 vendor 分区缺 vendor SELinux 版本标记，common/fix_vendor_avc 的
#       check_file_exists 会直接 FAIL。实测（DNA_ace6）：plat_sepolicy_vers.txt 已存在
#       （当前底包为 202404），只有 genfs_labels_version.txt 缺失——不同 ColorOS 构建
#       缺的不一定相同，故不能写死单一版本。
# 方案：以底包已存在的一方为权威；缺失的一方按已存在方的值补齐（不覆盖底包已有值），
#       两者都不存在时才回退到内置默认（与原包 mi_vendor 一致的 202504）。
# 注意：
#   - plat_sepolicy_vers 与 genfs_labels_version 必须同值：genfs 版本须与底包
#     vendor_sepolicy.cil 的基线一致，否则 init 用错误的 genfs 版本解析 policy 会启动
#     失败（实测 Ace 6 DSU 一屏后 fastboot）。
#   - 若底包两个文件都存在但互不同值，属底包本身冲突，本补丁不静默改写，直接失败交人工。
#   - 补齐后底包版本标记自洽，common/fix_vendor_avc 的 --allow-version-mismatch 跨 ABI
#     降级分支在此机型上不再触发（保留作保险）。
#   - 6T 底包不缺这两个文件，无需加入 Ace 6T 流程；误加时文件已存在会按同值校验跳过。

init_port_env "${1:-}"

std_print "Ace 6 vendor SELinux 基础设施文件补齐（版本标记以底包已存在值为准，缺失方按同值补齐）"
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

# 版本标记以底包已存在的一方为权威：读取已存在文件（不存在返回空串）。
# 已存在时校验非空、纯数字、非符号链接；两者都缺失时由调用方回退内置默认。
readonly default_selinux_version='202504'
plat_file="$vendor_selinux/plat_sepolicy_vers.txt"
genfs_file="$vendor_selinux/genfs_labels_version.txt"

read_version_file() {
	local target_file="$1"
	local display_name="${target_file#"$vendor_selinux"/}"
	local content
	if [[ -L "$target_file" ]]; then
		err_print "SELinux 版本标记文件不能是符号链接：$target_file"
		exit 1
	fi
	if [[ ! -e "$target_file" ]]; then
		return 0
	fi
	if [[ ! -f "$target_file" ]]; then
		err_print "SELinux 版本标记目标不是普通文件：$target_file"
		exit 1
	fi
	content="$(tr -d '[:space:]' < "$target_file")"
	if [[ -z "$content" ]]; then
		err_print "SELinux 版本标记文件存在但为空：$target_file"
		exit 1
	fi
	if [[ ! "$content" =~ ^[0-9]+$ ]]; then
		err_print "SELinux 版本标记应为纯数字：${display_name}（当前值 ${content}）"
		exit 1
	fi
	printf '%s\n' "$content"
}

# 缺失时按权威值补齐（本来就要新增的文件）；已存在则跳过，不覆盖底包或前次补丁的值。
write_version_file() {
	local target_file="$1"
	local version="$2"
	local display_name="${target_file#"$vendor_selinux"/}"
	local temporary_file
	if [[ -e "$target_file" ]]; then
		std_print "已存在: vendor/etc/selinux/${display_name}（当前值 $(read_version_file "$target_file")），跳过"
		return 0
	fi
	temporary_file="$(mktemp "${target_file}.tmp.XXXXXX")"
	temporary_files+=("$temporary_file")
	printf '%s\n' "$version" > "$temporary_file"
	chmod 0644 -- "$temporary_file"
	mv -f -- "$temporary_file" "$target_file"
	std_print "✅ 已写入: vendor/etc/selinux/${display_name}（内容 ${version}）"
}

plat_vers="$(read_version_file "$plat_file")"
genfs_vers="$(read_version_file "$genfs_file")"

# 以已存在的一方为权威；两者都不存在时回退内置默认。
if [[ -n "$plat_vers" ]]; then
	shared_vers="$plat_vers"
elif [[ -n "$genfs_vers" ]]; then
	shared_vers="$genfs_vers"
else
	shared_vers="$default_selinux_version"
	std_print "底包两个版本标记都不存在，回退内置默认 ${shared_vers}"
fi

write_version_file "$plat_file" "$shared_vers"
write_version_file "$genfs_file" "$shared_vers"

# 两个版本标记必须同值，否则 init 解析 vendor policy 时 genfs 基线错位。
# 底包两个文件都存在却互不同值时不静默改写，直接失败交人工处理。
plat_vers="$(read_version_file "$plat_file")"
genfs_vers="$(read_version_file "$genfs_file")"
if [[ "$plat_vers" != "$genfs_vers" ]]; then
	err_print "plat_sepolicy_vers（${plat_vers}）与 genfs_labels_version（${genfs_vers}）不同值，init 解析 policy 会启动失败"
	exit 1
fi

std_print "✅ vendor SELinux 版本标记就绪：plat_sepolicy_vers=${plat_vers}，genfs_labels_version=${genfs_vers}"
std_print "处理完成"
