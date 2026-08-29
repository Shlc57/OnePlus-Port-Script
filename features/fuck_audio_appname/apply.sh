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

std_print "阻止 HyperOS audio policy 向 Oplus HAL 下发 appname 遥测参数"
std_print "仅 NOP 两个 system_ext ARM64 库内已确认的 8 个 setParameters 调用点"
std_print

patcher="$patcher_dir/patch_audio_appname.py"
if [[ ! -f "$patcher" || -L "$patcher" ]]; then
	err_print "音频 appname 定点修补器不存在或不是普通文件：$patcher"
	exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
	err_print "缺少 python3，无法执行音频 appname 定点修补"
	exit 1
fi

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
declare -A target_files=(
	[libaudiopolicymanagerimpl.so]="$project_dir/system_ext/lib64/libaudiopolicymanagerimpl.so"
	[libmiaudiopolicymanager.so]="$project_dir/system_ext/lib64/libmiaudiopolicymanager.so"
)
library_names=(
	libaudiopolicymanagerimpl.so
	libmiaudiopolicymanager.so
)
declare -a active_libraries=()
declare -A initial_states=()

for library_name in "${library_names[@]}"; do
	target_file="${target_files[$library_name]}"
	if [[ -L "$target_file" ]]; then
		err_print "不支持修改符号链接音频库：$target_file"
		exit 1
	elif [[ ! -e "$target_file" ]]; then
		warn_print "待修补的音频库不存在，跳过：${target_file#"$project_dir"/}"
		continue
	elif [[ ! -f "$target_file" ]]; then
		err_print "待修补的音频库不是普通文件：$target_file"
		exit 1
	fi
	active_libraries+=("$library_name")
done

if (( ${#active_libraries[@]} == 0 )); then
	skip_print "没有可修补的 system_ext ARM64 音频库"
	std_print "处理完成"
	exit 0
fi

system_ext_contexts="$(get_part_contexts_path system_ext)"
system_ext_fsconfig="$(get_part_fsconfig_path system_ext)"
for metadata_file in "$system_ext_contexts" "$system_ext_fsconfig"; do
	if [[ -L "$metadata_file" ]]; then
		err_print "system_ext metadata 不能是符号链接：$metadata_file"
		exit 1
	fi
	check_file_exists "$metadata_file"
done

validate_context_entry() {
	local library_name="${1:-}"
	local expected_path="/system_ext/lib64/$library_name"
	local expected_context="u:object_r:system_lib_file:s0"

	awk -v expected_path="$expected_path" -v expected_context="$expected_context" '
		/^[[:space:]]*($|#)/ { next }
		{
			path = $1
			gsub(/\\/, "", path)
			if (path == expected_path) {
				matches++
				if (NF == 2 && $2 == expected_context) {
					valid++
				}
			}
		}
		END { exit !(matches == 1 && valid == 1) }
	' "$system_ext_contexts"
}

validate_fsconfig_entry() {
	local library_name="${1:-}"
	local expected_path="system_ext/lib64/$library_name"

	awk -v expected_path="$expected_path" '
		/^[[:space:]]*($|#)/ { next }
		$1 == expected_path {
			matches++
			if (NF == 4 && $2 == "0" && $3 == "0" && $4 == "0644") {
				valid++
			}
		}
		END { exit !(matches == 1 && valid == 1) }
	' "$system_ext_fsconfig"
}

# 在创建临时产物和写回工作树前，先完成两个目标的 metadata、ELF 与语义锚点全量预检。
for library_name in "${active_libraries[@]}"; do
	if ! validate_context_entry "$library_name"; then
		err_print "system_ext contexts 缺少唯一且正确的音频库条目：/system_ext/lib64/$library_name"
		exit 1
	fi
	if ! validate_fsconfig_entry "$library_name"; then
		err_print "system_ext fsconfig 缺少唯一的 0 0 0644 音频库条目：system_ext/lib64/$library_name"
		exit 1
	fi
	target_file="${target_files[$library_name]}"
	if ! initial_states["$library_name"]="$(
		python3 "$patcher" check --library "$library_name" --file "$target_file"
	)"; then
		err_print "音频库 ELF、语义锚点或调用点状态不受支持：${target_file#"$project_dir"/}"
		exit 1
	fi
done

staging_dir="$(mktemp -d "${TMPDIR:-/tmp}/fix-audio-appname.apply.XXXXXX")"
declare -A staged_files=()

for library_name in "${active_libraries[@]}"; do
	target_file="${target_files[$library_name]}"
	staged_file="$staging_dir/$library_name"
	cp -a -- "$target_file" "$staged_file"
	python3 "$patcher" patch --library "$library_name" --file "$staged_file" >/dev/null
	python3 "$patcher" check \
		--library "$library_name" \
		--file "$staged_file" \
		--expected patched >/dev/null
	staged_files["$library_name"]="$staged_file"
done

for library_name in "${active_libraries[@]}"; do
	target_file="${target_files[$library_name]}"
	replace_file_if_different "${staged_files[$library_name]}" "$target_file"
	python3 "$patcher" check \
		--library "$library_name" \
		--file "$target_file" \
		--expected patched >/dev/null
	if [[ "${initial_states[$library_name]}" == "patched" ]]; then
		skip_print "已是目标状态：${target_file#"$project_dir"/}"
	else
		std_print "✅ 已定点修补：${target_file#"$project_dir"/}"
	fi
done

std_print "未修改 32 位库、路由/音量控制与 SELinux 策略"
std_print "处理完成"
