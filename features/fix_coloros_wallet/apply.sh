#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "安装 ColorOS 钱包五件套（FinShellWallet/TasWallet/UPTsmService/HeytapHTMS/EidService）"
std_print "来源：模块 prebuilt（目标机型底包 system 提取产物）；目标：原包 system、system_ext"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154

# 钱包五件套清单：分区 运行时 contexts 路径。布局与 ColorOS 底包一致，五件套必须
# 整体安装，不允许部分安装造成 FinShell 与 TAS/HTMS/TSM 依赖断裂。
declare -a wallet_apps=(
	"system FinShellWallet"
	"system TasWallet"
	"system UPTsmService"
	"system HeytapHTMS"
	"system_ext EidService"
)

declare -a temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

check_partition_metadata_tool >/dev/null
for part_name in system system_ext; do
	check_part_exists "$part_name"
	check_file_exists "$(get_part_contexts_path "$part_name")"
	check_file_exists "$(get_part_fsconfig_path "$part_name")"
done

# 分区最终工作树根：system 分区文件树位于 system/system/...；system_ext 不嵌套。
# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
partition_worktree_root() {
	local part_name="${1:-}"
	case "$part_name" in
		system)
			printf '%s\n' "$project_dir/system/system"
			;;
		system_ext)
			printf '%s\n' "$project_dir/system_ext"
			;;
		*)
			err_print "钱包五件套不支持的目标分区：$part_name"
			return 1
			;;
	esac
}

prebuilt_root="$patcher_dir/prebuilt"
declare -a missing_apps=()
prepare_wallet_sources() {
	local app_entry part_name app_name
	local source_dir source_apk

	for app_entry in "${wallet_apps[@]}"; do
		read -r part_name app_name <<<"$app_entry"
		source_dir="$prebuilt_root/$part_name/app/$app_name"
		source_apk="$source_dir/$app_name.apk"

		if [[ ! -d "$source_dir" ]]; then
			missing_apps+=("$part_name/app/$app_name")
			continue
		fi
		if [[ -L "$source_apk" || ! -f "$source_apk" ]]; then
			missing_apps+=("$part_name/app/$app_name（缺少 $app_name.apk）")
			continue
		fi
		if [[ -n "$(find "$source_dir" -type l -print -quit)" ]]; then
			err_print "预置钱包来源不允许包含符号链接：${source_dir#"$patcher_dir"/}"
			return 1
		fi
	done
}

if [[ -e "$prebuilt_root" && ! -d "$prebuilt_root" ]]; then
	err_print "钱包预置来源不是普通目录：$prebuilt_root"
	exit 1
fi
prepare_wallet_sources
if [[ ! -d "$prebuilt_root" || ${#missing_apps[@]} -gt 0 ]]; then
	if [[ ! -d "$prebuilt_root" ]]; then
		warn_print "钱包预置来源目录不存在：${prebuilt_root#"$port_dir"/}"
	fi
	for missing_item in "${missing_apps[@]}"; do
		warn_print "钱包五件套预置产物缺失：prebuilt/$missing_item"
	done
	warn_print "请从目标机型底包 ROM 的 system.img 提取五件套后放入上述路径，" \
		"布局保持 app/<App>/<App>.apk 与 lib/arm64 原样"
	skip_print "钱包五件套未就绪，整体跳过安装"
	exit 0
fi

# 校验全部通过后才动工作树。copy_tree_missing_only 只补缺失文件，已存在且内容
# 相同则幂等跳过；目标冲突（内容不同/类型不符）视为错误。
for app_entry in "${wallet_apps[@]}"; do
	read -r part_name app_name <<<"$app_entry"
	worktree_root="$(partition_worktree_root "$part_name")"
	source_dir="$prebuilt_root/$part_name/app/$app_name"
	target_dir="$worktree_root/app/$app_name"
	copy_tree_missing_only "$source_dir" "$target_dir"
	std_print "✅ 钱包应用已就绪 $app_name（${part_name}）"
done

# 按复制后的目标树补齐 metadata。路径约定与原包一致：fsconfig 为项目目录相对全路径
# （system 分区为 system/system/app/...，system_ext 为 system_ext/app/...），
# contexts 为 "/" + 同一相对路径；fsconfig 目录 0755 / 文件 0644，无 capabilities 列。
append_tree_metadata() {
	local part_name="${1:-}"
	local fsconfig_patch contexts_patch
	local app_entry app_part_name app_name app_target app_contexts_root
	local source_path relative_path entry_mode

	fsconfig_patch="$(mktemp "$(get_config_path ".wallet_fsconfig.XXXXXX")")"
	temporary_files+=("$fsconfig_patch")
	contexts_patch="$(mktemp "$(get_config_path ".wallet_contexts.XXXXXX")")"
	temporary_files+=("$contexts_patch")

	for app_entry in "${wallet_apps[@]}"; do
		read -r app_part_name app_name <<<"$app_entry"
		[[ "$app_part_name" == "$part_name" ]] || continue
		app_target="$(partition_worktree_root "$part_name")/app/$app_name"
		app_contexts_root="/${app_target#"$project_dir"/}"
		printf '%s(/.*)? u:object_r:system_file:s0\n' "$app_contexts_root" \
			>> "$contexts_patch"
		while IFS= read -r -d '' source_path; do
			relative_path="${source_path#"$project_dir"/}"
			if [[ -d "$source_path" ]]; then
				entry_mode=0755
			else
				entry_mode=0644
			fi
			printf '%s 0 0 %s\n' "$relative_path" "$entry_mode" >> "$fsconfig_patch"
		done < <(find "$app_target" -mindepth 0 -print0)
	done

	merge_fsconfig_file "$fsconfig_patch" "$(get_part_fsconfig_path "$part_name")"
	merge_contexts_file "$contexts_patch" "$(get_part_contexts_path "$part_name")"
}

append_tree_metadata system
append_tree_metadata system_ext
std_print "✅ 钱包五件套 contexts 与 fsconfig 已合并"

std_print "处理完成"
