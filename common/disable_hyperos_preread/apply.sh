#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "关闭 HyperOS iorap 预读（iorapd 依赖底包内核不存在的 /dev/iorap_dev）"
std_print "来源：原包 system_ext 服务定义（只读预检）；目标：product 属性默认值、odm 运行时 rc"
std_print

preread_prop="persist.sys.stability.PrereadEnable"
# project_dir 由 tools.sh 的 init_port_env 注入，本补丁不本地赋值。
# shellcheck disable=SC2154
launch_boost_rc="$project_dir/system_ext/etc/init/init.launch_boost.rc"
product_build_prop="$project_dir/product/etc/build.prop"
odm_rc_dir="$project_dir/odm/etc/init"
odm_rc_target="$odm_rc_dir/disable_hyperos_preread.rc"

declare -a temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

# rc 与 metadata 落在 odm，是本次改动不可缺的前提；缺失应在写工作树前失败。
check_part_exists odm
odm_contexts="$(get_part_contexts_path odm)"
odm_fsconfig="$(get_part_fsconfig_path odm)"
check_file_exists "$odm_contexts"
check_file_exists "$odm_fsconfig"

# 只读预检原包服务定义：iorapd 的启停由它自带的属性触发器驱动，禁用只需把属性
# 置 false。原包结构变化（无该 rc 或无 service iorapd）时不再依赖 stop 命令，
# 属性禁用仍然成立。
service_declared=0
if [[ -L "$launch_boost_rc" ]]; then
	err_print "原包 launch boost rc 不能是符号链接：$launch_boost_rc"
	exit 1
elif [[ ! -f "$launch_boost_rc" ]]; then
	warn_print "未找到原包 iorapd 服务定义：system_ext/etc/init/init.launch_boost.rc（仅写入属性禁用）"
elif ! grep -q '^service iorapd ' "$launch_boost_rc"; then
	warn_print "原包 init.launch_boost.rc 不再定义 service iorapd（仅写入属性禁用）"
else
	service_declared=1
fi

# 默认值写进 product，让干净 data 上该属性在加载期就是 false，start 触发器不成立。
# prop 子步骤不因目标文件缺失而失败，只警告并跳过本步骤。
if [[ -f "$product_build_prop" ]]; then
	current_prop_value="$(read_prop_value "$preread_prop" "$product_build_prop" 2>/dev/null || true)"
	if [[ "$current_prop_value" == "false" ]]; then
		skip_print "product 默认值已是 ${preread_prop}=false"
	else
		ensure_prop "$product_build_prop" "$preread_prop" "false"
		std_print "✅ product 默认值已写入 ${preread_prop}=false"
	fi
else
	warn_print "未找到 product/etc/build.prop，跳过属性默认值子步骤"
fi

# persist. 属性在 /data/property 中的值会覆盖 build.prop 默认值，因此补一条 odm rc：
# 一旦该属性被置 true（持久值回填或用户开启应用预加载），立刻改回 false，
# 由原包 rc 自带的 false 触发器 stop iorapd。stop 是 init 自身动作，不依赖
# 属性写许可，作为 setprop 被拒时的兜底。
generated_rc="$(mktemp "$(get_config_path '.disable_hyperos_preread.rc.XXXXXX')")"
temporary_files+=("$generated_rc")
{
	printf '%s\n' \
		"# 关闭 HyperOS iorap 预读（common/disable_hyperos_preread）。" \
		"# iorapd 由原包 system_ext/etc/init/init.launch_boost.rc 按 ${preread_prop}" \
		"# 的 true/false 触发器 start/stop；它依赖 /dev/iorap_dev，OnePlus 底包内核" \
		"# 没有该节点，服务起即失败并被 init 无限重启。persist 属性的 /data 值会覆盖" \
		"# build.prop 默认值，故这里把 true 改回 false；stop 由 init 自身执行，" \
		"# 不依赖属性写许可，作为 setprop 被策略拒绝时的兜底。" \
		"on property:${preread_prop}=true"
	printf '    setprop %s false\n' "$preread_prop"
	if (( service_declared == 1 )); then
		printf '    stop iorapd\n'
	fi
} > "$generated_rc"

if [[ -L "$odm_rc_target" ]]; then
	err_print "禁用 iorap 的 rc 目标不能是符号链接：$odm_rc_target"
	exit 1
fi
if [[ -f "$odm_rc_target" ]] && cmp -s -- "$generated_rc" "$odm_rc_target"; then
	skip_print "禁用 iorap 的 rc 已存在且内容一致，同步 metadata"
else
	mkdir -p -- "$odm_rc_dir"
	replace_file_if_different "$generated_rc" "$odm_rc_target"
	# replace_file_if_different 用 cp -a 保留来源（mktemp 0600）权限，显式补齐。
	chmod 0644 -- "$odm_rc_target"
	std_print "✅ 禁用 iorap 的 rc 已写入 odm"
fi

temporary_fsconfig="$(mktemp "$(get_config_path '.disable_hyperos_preread_fsconfig.XXXXXX')")"
temporary_contexts="$(mktemp "$(get_config_path '.disable_hyperos_preread_contexts.XXXXXX')")"
temporary_files+=("$temporary_fsconfig" "$temporary_contexts")
printf '%s\n' "odm/etc/init/disable_hyperos_preread.rc 0 0 0644" > "$temporary_fsconfig"
printf '%s\n' '/odm/etc/init/disable_hyperos_preread\.rc u:object_r:vendor_configs_file:s0' > "$temporary_contexts"
merge_fsconfig_file "$temporary_fsconfig" "$odm_fsconfig"
merge_contexts_file "$temporary_contexts" "$odm_contexts"

std_print "处理完成（真机验证边界：iorapd 重启环消失仅在 Ace 6T 真机确认，其余机型按同类内核前提推断）"
