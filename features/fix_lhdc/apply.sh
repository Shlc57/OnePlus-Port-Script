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

std_print "向当前 Bluetooth APEX 注入 LHDC V5 encoder bridge/backend"
std_print "重打包 system/system/apex/com.android.bt.apex，不生成 Mountify 覆盖"
std_print "使用项目自有 AVB RSA-4096 密钥重建 payload hashtree/vbmeta"
warn_print "原样保留外层 META-INF 与 APK v2/v3 Signing Block；payload AVB 与 apex_pubkey 使用项目密钥"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
target_apex="$project_dir/system/system/apex/com.android.bt.apex"
system_build_prop="$project_dir/system/system/build.prop"
repacker="$patcher_dir/repack_bt_apex.py"
prebuilt_dir="$patcher_dir/prebuilt/system/apex/com.android.bt/lib64"
bridge_source="$patcher_dir/source/lhdc_cold.cpp"
avb_key="$patcher_dir/keys/com.android.bt.avb.pem"

# 先只校验日志属性目标；实际写回延后到 APEX 依赖与输入预检完成后。
system_build_prop_ready=0
if [[ -L "$system_build_prop" ]]; then
	err_print "不支持直接修改符号链接属性文件：$system_build_prop"
	exit 1
elif [[ ! -e "$system_build_prop" ]]; then
	warn_print "系统属性目标不存在，跳过 BTAudioSessionAidl 日志级别：${system_build_prop#"$project_dir"/}"
elif [[ ! -f "$system_build_prop" ]]; then
	err_print "系统属性目标不是普通文件：$system_build_prop"
	exit 1
else
	validate_prop_file "$system_build_prop"
	system_build_prop_ready=1
fi

apply_bt_log_property() {
	if (( system_build_prop_ready == 1 )); then
		ensure_prop "$system_build_prop" "log.tag.BTAudioSessionAidl" "S"
		std_print "✅ 已设置 log.tag.BTAudioSessionAidl=S"
	fi
}

if [[ -L "$target_apex" ]]; then
	err_print "不支持替换符号链接 Bluetooth APEX：$target_apex"
	exit 1
elif [[ ! -e "$target_apex" ]]; then
	apply_bt_log_property
	warn_print "待修补的 Bluetooth APEX 不存在，跳过：${target_apex#"$project_dir"/}"
	std_print "处理完成"
	exit 0
elif [[ ! -f "$target_apex" ]]; then
	err_print "Bluetooth APEX 不是普通文件：$target_apex"
	exit 1
fi

system_contexts="$(get_part_contexts_path system)"
system_fsconfig="$(get_part_fsconfig_path system)"

for input_file in \
	"$repacker" \
	"$bridge_source" \
	"$avb_key" \
	"$system_contexts" \
	"$system_fsconfig"; do
	if [[ -L "$input_file" || ! -f "$input_file" ]]; then
		err_print "LHDC APEX 输入不存在、不是普通文件或为符号链接：$input_file"
		exit 1
	fi
done

if ! awk '
	/^[[:space:]]*($|#)/ { next }
	{
		path = $1
		gsub(/\\/, "", path)
		if (path == "/system/system/apex/com.android.bt.apex") {
			matches++
			if (NF == 2 && $2 == "u:object_r:system_file:s0") valid++
		}
	}
	END { exit !(matches == 1 && valid == 1) }
' "$system_contexts"; then
	err_print "system contexts 缺少唯一正确的 Bluetooth APEX 标签"
	exit 1
fi

if ! awk '
	/^[[:space:]]*($|#)/ { next }
	$1 == "system/system/apex/com.android.bt.apex" {
		matches++
		if (NF == 4 && $2 == "0" && $3 == "0" && $4 == "0644") valid++
	}
	END { exit !(matches == 1 && valid == 1) }
' "$system_fsconfig"; then
	err_print "system fsconfig 缺少唯一的 Bluetooth APEX 0 0 0644 条目"
	exit 1
fi

for command_name in python3 debugfs e2fsck resize2fs truncate patchelf readelf; do
	if ! command -v "$command_name" >/dev/null 2>&1; then
		err_print "缺少 LHDC APEX 重打包依赖：$command_name"
		exit 1
	fi
done

resolve_avbtool() {
	local candidate
	local -a candidates=()

	if [[ -n "${AVBTOOL:-}" ]]; then
		candidates+=("$AVBTOOL")
	fi
	if command -v avbtool >/dev/null 2>&1; then
		candidates+=("$(command -v avbtool)")
	fi
	candidates+=(
		"$project_dir/../../tools/build-tools/linux_musl-x86/bin/avbtool"
		"$project_dir/../tools/build-tools/linux_musl-x86/bin/avbtool"
	)
	for candidate in "${candidates[@]}"; do
		if [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

resolve_zipalign() {
	local candidate
	local sdk_root
	local -a candidates=()

	if [[ -n "${ZIPALIGN:-}" ]]; then
		candidates+=("$ZIPALIGN")
	fi
	if command -v zipalign >/dev/null 2>&1; then
		candidates+=("$(command -v zipalign)")
	fi
	for sdk_root in "${ANDROID_SDK_ROOT:-}" "${ANDROID_HOME:-}" /home/yango/AndroidSdk; do
		[[ -n "$sdk_root" && -d "$sdk_root/build-tools" ]] || continue
		candidate="$({
			find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 \
				-type f -name zipalign -perm -u+x -print
		} | LC_ALL=C sort -V | tail -n 1)"
		if [[ -n "$candidate" ]]; then
			candidates+=("$candidate")
		fi
	done
	for candidate in "${candidates[@]}"; do
		if [[ -f "$candidate" && ! -L "$candidate" && -x "$candidate" ]]; then
			printf '%s\n' "$candidate"
			return 0
		fi
	done
	return 1
}

if ! avbtool_command="$(resolve_avbtool)"; then
	err_print "缺少 avbtool；可通过 AVBTOOL 指定可执行文件"
	exit 1
fi
if ! zipalign_command="$(resolve_zipalign)"; then
	err_print "缺少 zipalign；可通过 ZIPALIGN 指定可执行文件"
	exit 1
fi

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/fix-lhdc.apply.XXXXXX")"
staged_apex="$staging_dir/com.android.bt.apex"
patch_report="$staging_dir/PATCH_REPORT.txt"

if ! source_state="$(
	PYTHONDONTWRITEBYTECODE=1 python3 "$repacker" \
		--input "$target_apex" \
		--output "$staged_apex" \
		--prebuilt-dir "$prebuilt_dir" \
		--bridge-source "$bridge_source" \
		--report "$patch_report" \
		--avbtool "$avbtool_command" \
		--zipalign "$zipalign_command" \
		--avb-key "$avb_key"
)"; then
	err_print "Bluetooth APEX LHDC 重打包失败"
	exit 1
fi

if [[ "$source_state" != "original" && "$source_state" != "completed" ]]; then
	err_print "LHDC APEX 重打包器返回未知状态：$source_state"
	exit 1
fi
for generated_file in "$staged_apex" "$patch_report"; do
	if [[ ! -f "$generated_file" || -L "$generated_file" ]]; then
		err_print "LHDC APEX 重打包产物缺失或类型错误：$generated_file"
		exit 1
	fi
done

apply_bt_log_property

if [[ "$source_state" == "completed" ]]; then
	skip_print "Bluetooth APEX 已是本模块的 LHDC 目标状态"
else
	chmod --reference="$target_apex" -- "$staged_apex"
	replace_file_if_different "$staged_apex" "$target_apex"
	if [[ ! -f "$target_apex" || -L "$target_apex" ]] || ! cmp -s -- "$staged_apex" "$target_apex"; then
		err_print "Bluetooth APEX 原子替换后字节校验失败"
		exit 1
	fi
	std_print "✅ 已重打包并替换：${target_apex#"$project_dir"/}"
fi

warn_print "外层 META-INF 与 APK v2/v3 Signing Block 均保留原始字节，未重新生成签名"
std_print "payload AVB hashtree/vbmeta 已使用项目密钥重建并完成主机校验"
std_print "未修改 vendor Audio HAL/PAL/LHDC policy，也未新增 SELinux allow"
std_print "处理完成"
