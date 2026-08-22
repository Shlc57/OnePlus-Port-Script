#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

# shellcheck disable=SC2154 # project_dir is exported by init_port_env/tools.sh.
vendor_modprobe_script="$project_dir/vendor/bin/vendor_modprobe.sh"

check_part_exists vendor

if [[ -L "$vendor_modprobe_script" ]]; then
	err_print "vendor_modprobe.sh 不能是符号链接：$vendor_modprobe_script"
	exit 1
elif [[ ! -e "$vendor_modprobe_script" ]]; then
	warn_print "vendor_modprobe.sh 不存在，跳过 zram blocklist：${vendor_modprobe_script#"$project_dir"/}"
	std_print "处理完成"
	exit 0
elif [[ ! -f "$vendor_modprobe_script" ]]; then
	err_print "vendor_modprobe.sh 不是普通文件：$vendor_modprobe_script"
	exit 1
fi

ensure_blocklist_entries() {
	local temporary_file
	local token
	local missing_tokens=""
	local -a blocklist_tokens=(
		zram
		zsmalloc
		oplus_bsp_hybridswap_zram
		oplus_bsp_zram_opt
		oplus_bsp_fg_protect
		oplus_exit_mm_optimize
		oplus_bsp_zsmalloc
	)

	for token in "${blocklist_tokens[@]}"; do
		if ! grep -Fq -- "-e $token" "$vendor_modprobe_script"; then
			missing_tokens+=" -e $token"
		fi
	done
	if [[ -z "$missing_tokens" ]]; then
		return 0
	fi

	temporary_file="$(mktemp "${vendor_modprobe_script}.tmp.XXXXXX")"
	# shellcheck disable=SC2016 # 保留写入目标脚本所需的字面量 $blocklist_expr。
	blocklist_prefix='    blocklist_expr="$blocklist_expr'
	# shellcheck disable=SC2016 # awk 程序中的 $0 是 awk 字段变量，不是 Shell 展开。
	if ! awk -v blocklist_prefix="$blocklist_prefix" -v missing_tokens="$missing_tokens" '
		BEGIN {
			blocklist = blocklist_prefix missing_tokens "\""
		}
		!inserted && $0 ~ /^[[:space:]]*# Filter out modules/ {
			print blocklist
			inserted = 1
		}
		{ print }
		END {
			if (!inserted) {
				print blocklist
			}
		}
	' "$vendor_modprobe_script" > "$temporary_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
	_install_generated_file "$temporary_file" "$vendor_modprobe_script"
}

ensure_blocklist_entries

std_print "已隐藏 vendor_dlkm 的 zram/zsmalloc，回退到 system_dlkm 版本"
std_print "已幂等屏蔽 Oplus zram/swap 优化模块"
std_print "处理完成"
