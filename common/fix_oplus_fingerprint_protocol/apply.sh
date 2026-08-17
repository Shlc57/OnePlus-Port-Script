#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
staging_dir=''

cleanup() {
	if [[ -n "$staging_dir" && -d "$staging_dir" ]]; then
		find "$staging_dir" -depth -delete >/dev/null 2>&1 || true
	fi
}

trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

init_port_env "${1:-}"

std_print "适配 Oplus 指纹 HAL 到 Xiaomi 息屏 FOD 触摸协议"
std_print "SystemUI 直接使用 FOD 窗口原始触摸及时启动动画"
std_print "锁屏首次 ACQUIRED_GOOD 继续作为按下兜底，成功撞上息屏过程时先主动唤醒"
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

miui_systemui_apk="$project_dir/system_ext/priv-app/MiuiSystemUI/MiuiSystemUI.apk"
check_file_exists "$miui_systemui_apk"
if [[ -L "$miui_systemui_apk" ]]; then
	err_print "不支持修改符号链接 APK：$miui_systemui_apk"
	exit 1
fi

jar_patcher="$patcher_dir/patch_jar.sh"
systemui_patcher="$patcher_dir/patch_systemui.sh"
check_file_exists "$jar_patcher"
check_file_exists "$systemui_patcher"

staging_dir=$(mktemp -d "${TMPDIR:-/tmp}/fix-oplus-fingerprint-protocol.apply.XXXXXX")
staged_miui_services_jar="$staging_dir/miui-services.jar"
staged_miui_systemui_apk="$staging_dir/MiuiSystemUI.apk"
cp -a -- "$miui_services_jar" "$staged_miui_services_jar"
cp -a -- "$miui_systemui_apk" "$staged_miui_systemui_apk"

bash "$jar_patcher" "$staged_miui_services_jar"
bash "$systemui_patcher" "$staged_miui_systemui_apk"

replace_file_if_different "$staged_miui_services_jar" "$miui_services_jar"
replace_file_if_different "$staged_miui_systemui_apk" "$miui_systemui_apk"

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

stale_systemui_runtime_files=(
	priv-app/MiuiSystemUI/MiuiSystemUI.apk.fsv_meta
	priv-app/MiuiSystemUI/MiuiSystemUI.apk.prof
	priv-app/MiuiSystemUI/MiuiSystemUI.apk.prof.fsv_meta
)

for relative_path in "${stale_systemui_runtime_files[@]}"; do
	remove_path_if_exists "$project_dir/system_ext/$relative_path"
	remove_part_metadata_prefix system_ext "$relative_path"
done

remove_path_if_exists "$project_dir/system_ext/priv-app/MiuiSystemUI/oat"
remove_part_metadata_prefix system_ext "priv-app/MiuiSystemUI/oat"

std_print "✅ 已更新：system_ext/framework/miui-services.jar"
std_print "✅ 已更新：system_ext/priv-app/MiuiSystemUI/MiuiSystemUI.apk"
std_print "✅ 已清理：目标 JAR 的旧 profile、FS-Verity 元数据与 arm64 预编译产物"
std_print "✅ 已清理：MiuiSystemUI 的旧 profile、FS-Verity 元数据与预编译产物"
std_print "处理完成"
