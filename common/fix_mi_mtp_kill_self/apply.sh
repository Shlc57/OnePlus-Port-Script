#!/usr/bin/env bash
set -Eeuo pipefail

patcher_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

init_port_env "${1:-}"

std_print "隔离小米 MTP 与 DownloadProvider 进程"
std_print "避免启动期 DownloadProvider 自杀逻辑终止 MtpService"

check_part_exists system

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
mtp_dir="$project_dir/system/system/priv-app/MtpService"
mtp_apk="$mtp_dir/MtpService.apk"

if [[ -L "$mtp_apk" ]]; then
	err_print "不支持修改符号链接 APK：$mtp_apk"
	exit 1
elif [[ ! -e "$mtp_apk" ]]; then
	warn_print "待修补的 MtpService.apk 不存在，跳过：${mtp_apk#"$project_dir"/}"
	std_print "处理完成"
	exit 0
elif [[ ! -f "$mtp_apk" ]]; then
	err_print "待修补的 MtpService.apk 不是普通文件：$mtp_apk"
	exit 1
fi

check_file_exists "$(get_part_contexts_path system)"
check_file_exists "$(get_part_fsconfig_path system)"
check_partition_metadata_tool >/dev/null

bash "$patcher_dir/patch_mtp_service_apk.sh" "$mtp_apk"

# AndroidManifest 变更会使预编译产物与 fs-verity 元数据失效。
for relative_path in \
	'system/priv-app/MtpService/MtpService.apk.fsv_meta' \
	'system/priv-app/MtpService/MtpService.apk.prof' \
	'system/priv-app/MtpService/MtpService.apk.prof.fsv_meta' \
	'system/priv-app/MtpService/oat'; do
	remove_path_if_exists "$project_dir/system/$relative_path"
	remove_part_metadata_prefix system "$relative_path"
done

std_print "✅ 已隔离 MtpService 进程：android.process.mtp"
std_print "处理完成"
