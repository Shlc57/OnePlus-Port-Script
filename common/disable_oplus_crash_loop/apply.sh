#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "停掉底包里必然自杀的两个守护服务（qguard 缺 libbase.so、syshealthmon SIGSYS）"
std_print "来源：底包 vendor/odm 服务定义（只读预检）；目标：odm 运行时 rc 与该路径 metadata"
std_print

# project_dir 由 tools.sh 的 init_port_env 注入，本补丁不本地赋值。
# shellcheck disable=SC2154
vendor_rc_dir="$project_dir/vendor/etc/init"
odm_rc_dir="$project_dir/odm/etc/init"
target_rc_dir="$odm_rc_dir"
target_rc="$target_rc_dir/disable_oplus_crash_loop.rc"

# 真机取证到的两个崩溃环（2026-09-30 真我 Neo8，DSU/已刷机的移植侧系统）：
#   F linker : CANNOT LINK EXECUTABLE "/vendor/bin/qguard": library "libbase.so" not found
#   init     : Service 'qguard' (pid N) exited with status 1                → init.svc.qguard=restarting
#   libminijail: blocked syscall: lseek  → vendor.qti.syshealthmon-service 收 SIGSYS 被杀
#   init     : process with updatable components 'qguard|syshealthmon-service' exited 4 times in 4 minutes
# 两者在当前组合下从未成功运行：qguard 停在动态链接阶段（根因待定：文件真缺失，还是 vendor
# linker namespace 解析不到——真机历史上见过 /vendor/lib64/libbase.so 存在），且自身一条日志都没输出过；
# syshealthmon-service 被自带的 minijail seccomp 策略挡在 lseek 上。它们在启动早期就被 class_start
# 拉起，每 5 秒重拉一次，属纯 CPU 抖动源（真机 1 分钟 load 平均 9.3、峰值 11.2），还会把其他可更新
# 服务的重启拖进指数退避；而 ADSP/modem 的 SSR 通知在内核侧 qcom_sysmon/qcom_pd_mapper，不受影响。
declare -A service_binaries=(
	[qguard]="$project_dir/vendor/bin/qguard"
	[syshealthmon-service]="$project_dir/vendor/bin/vendor.qti.syshealthmon-service"
)
declare -a target_services=()

check_part_exists odm
odm_contexts="$(get_part_contexts_path odm)"
odm_fsconfig="$(get_part_fsconfig_path odm)"
check_file_exists "$odm_contexts"
check_file_exists "$odm_fsconfig"

# 只读预检：只对底包 rc 里真实定义过的服务下发 disable/stop。init 对未注册的
# 服务名执行 disable 会报错，这里从源头避免生成无效命令；一个都没有时整体跳过，
# 不写工作树、不改 metadata。
for service_name in qguard syshealthmon-service; do
	if ! grep -REqs "^service[[:space:]]+${service_name}[[:space:]]" \
		"$vendor_rc_dir" "$odm_rc_dir" 2>/dev/null; then
		warn_print "底包未定义 service ${service_name}，跳过该服务（不做任何下发）"
		continue
	fi
	if [[ ! -f "${service_binaries[$service_name]}" ]]; then
		warn_print "底包 service ${service_name} 的可执行文件不在预期路径：${service_binaries["$service_name"]#"$project_dir"/}（仍下发 disable，真机再核）"
	fi
	target_services+=("$service_name")
done

if (( ${#target_services[@]} == 0 )); then
	skip_print "底包没有 qguard / syshealthmon-service 任一服务定义，本补丁无事可做"
	std_print "处理完成"
	exit 0
fi

declare -a temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

# disable 让 init 不再由 class_start 拉起它们；boot_completed 的 stop 是兜底：
# 万一别处用 `start`/ctl.start 显式拉起，也会在开机完成时停掉，不留下重启环。
generated_rc="$(mktemp "$(get_config_path '.disable_oplus_crash_loop.rc.XXXXXX')")"
temporary_files+=("$generated_rc")
{
	printf '%s\n' \
		"# 停掉底包崩溃环服务（common/disable_oplus_crash_loop）。" \
		"# qguard 卡在动态链接（libbase.so 解析不到，原因未定性），自身从未输出日志；" \
		"# syshealthmon-service 被自带 minijail 策略 blocked syscall: lseek 而收 SIGSYS。" \
		"# 两者都被 init 每 5 秒重拉并记入 updatable 退避，只产生 CPU 抖动，不提供" \
		"# 移植侧需要的能力；ADSP/modem 的 SSR 通知在内核 qcom_sysmon，不受影响。" \
		"on early-init"
	for service_name in "${target_services[@]}"; do
		printf '    disable %s\n' "$service_name"
	done
	printf '%s\n' "on property:sys.boot_completed=1"
	for service_name in "${target_services[@]}"; do
		printf '    stop %s\n' "$service_name"
	done
} >"$generated_rc"

if [[ -L "$target_rc" ]]; then
	err_print "禁用崩溃环的 rc 目标不能是符号链接：$target_rc"
	exit 1
fi
if [[ -f "$target_rc" ]] && cmp -s -- "$generated_rc" "$target_rc"; then
	skip_print "禁用崩溃环的 rc 已存在且内容一致，仅同步 metadata"
else
	mkdir -p -- "$target_rc_dir"
	replace_file_if_different "$generated_rc" "$target_rc"
	# replace_file_if_different 用 cp -a 保留来源（mktemp 0600）权限，显式补齐。
	chmod 0644 -- "$target_rc"
	std_print "✅ 禁用崩溃环的 rc 已写入 odm/etc/init（服务：${target_services[*]}）"
fi

temporary_fsconfig="$(mktemp "$(get_config_path '.disable_oplus_crash_loop_fsconfig.XXXXXX')")"
temporary_contexts="$(mktemp "$(get_config_path '.disable_oplus_crash_loop_contexts.XXXXXX')")"
temporary_files+=("$temporary_fsconfig" "$temporary_contexts")
printf '%s\n' "odm/etc/init/disable_oplus_crash_loop.rc 0 0 0644" >"$temporary_fsconfig"
printf '%s\n' '/odm/etc/init/disable_oplus_crash_loop\.rc u:object_r:vendor_configs_file:s0' >"$temporary_contexts"
merge_fsconfig_file "$temporary_fsconfig" "$odm_fsconfig"
merge_contexts_file "$temporary_contexts" "$odm_contexts"

std_print "处理完成（真机验证边界：崩溃环消失需回传 issue_trace 的 11b_svc_state 与 load 轨迹确认）"
