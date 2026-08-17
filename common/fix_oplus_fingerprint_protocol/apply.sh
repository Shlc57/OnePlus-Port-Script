#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "适配 Oplus 指纹 HAL 到 Xiaomi 息屏 FOD 触摸协议"
std_print "锁屏首次 ACQUIRED_GOOD 映射为按下，成功撞上息屏过程时先主动唤醒"
std_print "认证结果、错误与新会话统一释放抬起状态"
std_print

check_part_exists system_ext
check_file_exists "$(get_part_contexts_path system_ext)"
check_file_exists "$(get_part_fsconfig_path system_ext)"
check_partition_metadata_tool >/dev/null

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
miui_services_jar="$project_dir/system_ext/framework/miui-services.jar"
check_file_exists "$miui_services_jar"
if [[ -L "$miui_services_jar" ]]; then
	err_print "不支持修改符号链接 JAR：$miui_services_jar"
	exit 1
fi

patcher="$patcher_dir/patch_jar.sh"
check_file_exists "$patcher"
bash "$patcher" "$miui_services_jar"

stale_runtime_files=(
	framework/miui-services.jar.fsv_meta
	framework/miui-services.jar.prof
	framework/miui-services.jar.prof.fsv_meta
	framework/oat/arm64/miui-services.art
	framework/oat/arm64/miui-services.art.fsv_meta
	framework/oat/arm64/miui-services.odex
	framework/oat/arm64/miui-services.odex.fsv_meta
	framework/oat/arm64/miui-services.vdex
	framework/oat/arm64/miui-services.vdex.fsv_meta
)

for relative_path in "${stale_runtime_files[@]}"; do
	remove_path_if_exists "$project_dir/system_ext/$relative_path"
	remove_part_metadata_prefix system_ext "$relative_path"
done

std_print "✅ 已更新：system_ext/framework/miui-services.jar"
std_print "✅ 已清理：目标 JAR 的旧 profile、FS-Verity 元数据与 arm64 预编译产物"
std_print "处理完成"
