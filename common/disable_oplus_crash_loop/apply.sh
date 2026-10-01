#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "停掉底包里必然自杀的守护服务（qguard / syshealthmon-service：linker namespace 解析不到依赖或被自带 seccomp 挡住，从未成功运行）"
std_print "来源：底包 vendor/odm 服务定义（只读预检）；目标：odm 运行时 rc 与该路径 metadata"
std_print

# project_dir 由 tools.sh 的 init_port_env 注入，本补丁不本地赋值。
# shellcheck disable=SC2154
vendor_rc_dir="$project_dir/vendor/etc/init"
odm_rc_dir="$project_dir/odm/etc/init"
target_rc_dir="$odm_rc_dir"
target_rc="$target_rc_dir/disable_oplus_crash_loop.rc"

# 真机取证到的崩溃环（2026-09-30 Neo8 与 6T 两台移植 DSU 均实测；2026-10-02 Ace 6T DSU 复核）：
#   F linker : CANNOT LINK EXECUTABLE "/vendor/bin/qguard": library "libbase.so" not found
#   init     : Service 'qguard' (pid N) exited with status 1                → init.svc.qguard=restarting
#   libminijail: blocked syscall: lseek  → vendor.qti.syshealthmon-service 收 SIGSYS 被杀
#   init     : process with updatable components 'qguard|syshealthmon-service' exited 4 times in 4 minutes
# 两者在当前组合下从未成功运行：qguard 停在动态链接阶段——6T 实机证明 /vendor/lib64/libbase.so 文件
# 存在，是 vendor linker namespace 解析不到（非文件缺失，补库无效），自身一条日志都没输出过；
# syshealthmon-service 被自带 minijail seccomp 挡在 lseek 收 SIGSYS。qguard(class late_start)/
# syshealthmon(class hal) 被 class_start 拉起后每 5 秒重拉，属纯 CPU 抖动源（Neo8 1 分钟 load 平均
# 9.3、峰值 11.2），还会把其他可更新服务的重启拖进指数退避；而 ADSP/modem 的 SSR 通知在内核侧
# qcom_sysmon/qcom_pd_mapper，不受影响。
#
# 不在本补丁处理的服务（明确排除）：
#   - 底包 Oplus FIDO HAL：服务名 `fidoca`（/odm/bin/hw/vendor.oplus.hardware.fido.fidoca@1.0-service），
#     Ace 6T DSU 实测 `init.svc.fidoca=running`、已注册 IFidoDaemon/default 与 fido2ca，是正常工作的
#     FIDO2/U2F/WebAuthn 提供者，绝不能 disable；早前把 CANNOT LINK 归给它属于同名误判。
#   - Xiaomi mfidoca：服务名 `vendor.mfidoca`（/odm/bin/fidoca），由 common/fix_mi_account 从 mi_odm 引入；
#     其自带 rc 已是 `class hal / oneshot / disabled`，只在 sys.boot_completed=1 时 start 一次，linker
#     失败后停在 stopped，不进 updatable_crashing 记账，不构成崩溃环；如需消除 CANNOT LINK 噪声，应在
#     fix_mi_account 内调整触发器，不由本补丁越界处理。
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
	skip_print "底包未定义 qguard / syshealthmon-service（或两者皆不适用），本补丁无事可做"
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
		"# qguard 卡在动态链接：实机证明 /vendor/lib64/libbase.so 存在，是 vendor linker namespace" \
		"# 解析不到（非文件缺失），自身从未输出日志；syshealthmon-service 被自带 minijail 策略" \
		"# blocked syscall: lseek 而收 SIGSYS。两者被 init 拉起后反复失败重拉并记入 updatable 退避，" \
		"# 只产生 CPU 抖动，不提供移植侧需要的能力；ADSP/modem 的 SSR 通知在内核 qcom_sysmon，不受影响。" \
		"# 注意：底包 Oplus FIDO HAL 服务名恰为 fidoca 但功能正常，不在本补丁范围；Xiaomi vendor.mfidoca" \
		"# 由 fix_mi_account 引入且 rc 自带 oneshot+disabled，只触发一次不构成崩溃环，也不由本补丁处理。" \
		"# disable 放 on boot（odm/vendor rc 此时已 import，早于 class_start hal 与 late_start）；" \
		"# 再用 on property:init.svc.<服务>=restarting 兜底，一旦 backoff 立即 stop，不依赖启动时机。" \
		"on boot"
	for service_name in "${target_services[@]}"; do
		printf '    disable %s\n' "$service_name"
	done
	for service_name in "${target_services[@]}"; do
		printf 'on property:init.svc.%s=restarting\n' "$service_name"
		printf '    stop %s\n' "$service_name"
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
