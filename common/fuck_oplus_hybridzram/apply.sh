#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

# shellcheck disable=SC2154 # project_dir is exported by init_port_env/tools.sh.
vendor_modprobe_script="$project_dir/vendor/bin/vendor_modprobe.sh"
system_dlkm_modprobe_script="$project_dir/vendor/bin/system_dlkm_modprobe.sh"

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

if [[ -L "$system_dlkm_modprobe_script" ]]; then
	err_print "system_dlkm_modprobe.sh 不能是符号链接：$system_dlkm_modprobe_script"
	exit 1
elif [[ ! -e "$system_dlkm_modprobe_script" ]]; then
	warn_print "system_dlkm_modprobe.sh 不存在，跳过 system_dlkm zram 依赖子步骤：${system_dlkm_modprobe_script#"$project_dir"/}"
	system_dlkm_modprobe_ready=0
elif [[ ! -f "$system_dlkm_modprobe_script" ]]; then
	err_print "system_dlkm_modprobe.sh 不是普通文件：$system_dlkm_modprobe_script"
	exit 1
else
	system_dlkm_modprobe_ready=1
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

ensure_system_zram_dependency_load() {
	local temporary_file

	if grep -Fq -- '# zram.ko depends on zsmalloc.ko; load both explicitly before the generic scan.' "$system_dlkm_modprobe_script"; then
		return 0
	fi

	temporary_file="$(mktemp "${system_dlkm_modprobe_script}.tmp.XXXXXX")"
	if ! awk '
		!inserted && $0 ~ /^for dir in \$\{SYSTEM_DLKM_DIR\} ;/ {
			print ""
			print "# zram.ko depends on zsmalloc.ko; load both explicitly before the generic scan."
			print "for system_module in zsmalloc zram; do"
			print "\tif [ -f ${SYSTEM_DLKM_DIR}/${system_module}.ko ]; then"
			print "\t\t${MODPROBE} -b -s -d ${SYSTEM_DLKM_DIR} -a ${SYSTEM_DLKM_DIR}/${system_module}.ko > /dev/null 2>&1 || true"
			print "\tfi"
			print "done"
			print ""
			inserted = 1
		}
		{ print }
		END {
			if (!inserted) {
				exit 1
			}
		}
	' "$system_dlkm_modprobe_script" > "$temporary_file"; then
		rm -f -- "$temporary_file"
		err_print "system_dlkm_modprobe.sh 缺少 system_dlkm 扫描入口，无法补齐 zram 依赖加载"
		return 1
	fi
	_install_generated_file "$temporary_file" "$system_dlkm_modprobe_script"
}

ensure_blocklist_entries
if (( system_dlkm_modprobe_ready == 1 )); then
	ensure_system_zram_dependency_load
fi

std_print "已隐藏 vendor_dlkm 的 zram/zsmalloc，回退到 system_dlkm 版本"
std_print "已幂等屏蔽 Oplus zram/swap 优化模块"
std_print "处理完成"
