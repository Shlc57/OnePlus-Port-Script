#!/bin/bash
set -euo pipefail

init_port_env "${1:-}"

std_print "适配目标设备线性马达触感"
std_print "来源：目标设备流程显式提供的 sys.haptic 属性；执行：开机完成后设置马达类型"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
source_build_prop="${LINEAR_HAPTIC_PROPERTIES_FILE:-}"
# shellcheck disable=SC2154
target_build_prop="$project_dir/odm/etc/build.prop"
vibrator_rc="$project_dir/odm/etc/init/vibrator-default.rc"
motor_type="${LINEAR_HAPTIC_MOTOR_TYPE:-}"

if [[ -z "$source_build_prop" || -z "$motor_type" ]]; then
	warn_print "未提供目标设备线性马达配置（LINEAR_HAPTIC_PROPERTIES_FILE/LINEAR_HAPTIC_MOTOR_TYPE），跳过补丁"
	std_print "处理完成"
	exit 0
fi
if [[ ! "$motor_type" =~ ^[A-Za-z0-9_.-]+$ ]]; then
	err_print "线性马达类型无效：$motor_type"
	exit 1
fi

patch_ready=1
for required_file in "$source_build_prop" "$target_build_prop" "$vibrator_rc"; do
	if [[ -L "$required_file" ]]; then
		err_print "不支持直接处理符号链接：$required_file"
		exit 1
	elif [[ ! -e "$required_file" ]]; then
		warn_print "线性震动属性相关文件不存在，跳过补丁：$required_file"
		patch_ready=0
		continue
	elif [[ ! -f "$required_file" ]]; then
		err_print "线性震动属性相关路径不是普通文件：$required_file"
		exit 1
	fi
done
if (( patch_ready == 0 )); then
	std_print "处理完成"
	exit 0
fi
validate_prop_file "$source_build_prop"

declare -a temporary_files=()
cleanup() {
	if (( ${#temporary_files[@]} > 0 )); then
		rm -f -- "${temporary_files[@]}"
	fi
}
trap cleanup EXIT

haptic_prop_patch="$(mktemp "$(get_config_path '.fix_linear_haptic_props.XXXXXX')")"
temporary_files+=("$haptic_prop_patch")
target_build_prop_next="$(mktemp "$(get_config_path '.fix_linear_haptic_build_prop.XXXXXX')")"
temporary_files+=("$target_build_prop_next")
vibrator_rc_next="$(mktemp "$(get_config_path '.fix_linear_haptic_rc.XXXXXX')")"
temporary_files+=("$vibrator_rc_next")

for excluded_prop_key in sys.haptic.motor sys.haptic.version; do
	if grep -Eq "^[[:space:]]*${excluded_prop_key//./\\.}[[:space:]]*=" "$source_build_prop"; then
		err_print "目标设备触感映射不得定义静态属性 $excluded_prop_key；马达类型由 LINEAR_HAPTIC_MOTOR_TYPE 单独配置"
		exit 1
	fi
done

if awk -v source_file="$source_build_prop" '
	function trim(value) {
		sub(/^[[:space:]]*/, "", value)
		sub(/[[:space:]]*$/, "", value)
		return value
	}
	{
		line = $0
		sub(/\r$/, "", line)
		candidate = line
		sub(/^[[:space:]]*/, "", candidate)
		if (candidate == "" || substr(candidate, 1, 1) == "#") {
			next
		}
		separator = index(candidate, "=")
		if (separator == 0) {
			next
		}
		key = trim(substr(candidate, 1, separator - 1))
		if (key !~ /^sys\.haptic\.[A-Za-z0-9_.-]+$/) {
			next
		}
		if (key in seen) {
			printf "! 目标设备触感属性重复：%s：%s\n", source_file, key > "/dev/stderr"
			invalid = 1
			next
		}
		seen[key] = 1
		value = trim(substr(candidate, separator + 1))
		if (value == "") {
			printf "! 目标设备触感属性值为空：%s：%s\n", source_file, key > "/dev/stderr"
			invalid = 1
			next
		}
		if (key == "sys.haptic.motor" || key == "sys.haptic.version") {
			next
		}
		print key "=" value
		kept++
	}
	END {
		if (invalid) {
			exit 1
		}
		if (kept == 0) {
			exit 3
		}
	}
' "$source_build_prop" > "$haptic_prop_patch"; then
	:
else
	awk_status=$?
	if (( awk_status == 3 )); then
		warn_print "目标设备配置没有可合并的 sys.haptic 属性，跳过线性震动补丁：$source_build_prop"
		std_print "处理完成"
		exit 0
	fi
	exit "$awk_status"
fi

validate_prop_file "$haptic_prop_patch"
haptic_prop_count="$(awk 'END { print NR }' "$haptic_prop_patch")"

if ! awk -v patch_file="$haptic_prop_patch" '
	function trim(value) {
		sub(/^[[:space:]]*/, "", value)
		sub(/[[:space:]]*$/, "", value)
		return value
	}
	function line_key(line, candidate, separator) {
		candidate = line
		sub(/^[[:space:]]*/, "", candidate)
		if (substr(candidate, 1, 1) == "#") {
			candidate = substr(candidate, 2)
			sub(/^[[:space:]]*/, "", candidate)
		}
		separator = index(candidate, "=")
		if (separator == 0) {
			return ""
		}
		return trim(substr(candidate, 1, separator - 1))
	}
	BEGIN {
		while ((getline patch_line < patch_file) > 0) {
			sub(/\r$/, "", patch_line)
			separator = index(patch_line, "=")
			key = trim(substr(patch_line, 1, separator - 1))
			value[key] = trim(substr(patch_line, separator + 1))
			order[++count] = key
		}
		close(patch_file)
	}
	{
		key = line_key($0)
		if (key == "sys.haptic.motor" || key == "sys.haptic.version") {
			next
		}
		if (key in value) {
			if (!(key in written)) {
				print key "=" value[key]
				written[key] = 1
			}
			next
		}
		print
	}
	END {
		for (order_index = 1; order_index <= count; order_index++) {
			key = order[order_index]
			if (!(key in written)) {
				print key "=" value[key]
			}
		}
	}
' "$target_build_prop" > "$target_build_prop_next"; then
	exit 1
fi

if ! awk -v patch_file="$haptic_prop_patch" -v target_file="$target_build_prop" '
	function trim(value) {
		sub(/^[[:space:]]*/, "", value)
		sub(/[[:space:]]*$/, "", value)
		return value
	}
	BEGIN {
		while ((getline patch_line < patch_file) > 0) {
			separator = index(patch_line, "=")
			expected[trim(substr(patch_line, 1, separator - 1))] = 1
		}
		close(patch_file)
	}
	{
		line = $0
		sub(/\r$/, "", line)
		candidate = line
		sub(/^[[:space:]]*/, "", candidate)
		if (candidate == "" || substr(candidate, 1, 1) == "#") {
			next
		}
		separator = index(candidate, "=")
		if (separator == 0) {
			next
		}
		key = trim(substr(candidate, 1, separator - 1))
		if (key == "sys.haptic.motor" || key == "sys.haptic.version") {
			printf "! 目标属性仍包含禁止的静态定义：%s：%s\n", target_file, key > "/dev/stderr"
			invalid = 1
		}
		if (key in expected) {
			found[key]++
		}
	}
	END {
		for (key in expected) {
			if (found[key] != 1) {
				printf "! 目标触感属性数量应为 1，实际为 %d：%s：%s\n", found[key], target_file, key > "/dev/stderr"
				invalid = 1
			}
		}
		exit(invalid ? 1 : 0)
	}
' "$target_build_prop_next"; then
	exit 1
fi

if ! awk -v rc_file="$vibrator_rc" -v motor_type="$motor_type" '
	function trim(value) {
		sub(/^[[:space:]]*/, "", value)
		sub(/[[:space:]]*$/, "", value)
		return value
	}
	{
		lines[NR] = $0
		stripped = trim($0)
		if ($0 !~ /^[[:space:]]/ && stripped !~ /^#/ && stripped != "") {
			if (stripped ~ /^on[[:space:]]+/) {
				action = stripped
			} else {
				action = ""
			}
		}
		if (stripped ~ /^setprop[[:space:]]+sys\.haptic\.motor([[:space:]]+|$)/) {
			field_count = split(stripped, fields, /[[:space:]]+/)
			if (field_count == 3 && fields[3] == motor_type && action == "on property:sys.boot_completed=1") {
				exact++
			} else {
				printf "! 发现冲突的 sys.haptic.motor 设置：%s：%s\n", rc_file, stripped > "/dev/stderr"
				invalid = 1
			}
		}
	}
	END {
		if (exact > 1) {
			printf "! 线性震动启动设置重复：%s\n", rc_file > "/dev/stderr"
			invalid = 1
		}
		if (invalid) {
			exit 1
		}
		for (line_index = 1; line_index <= NR; line_index++) {
			print lines[line_index]
		}
		if (exact == 0) {
			if (NR > 0 && lines[NR] != "") {
				print ""
			}
			print "on property:sys.boot_completed=1"
			print "    setprop sys.haptic.motor " motor_type
		}
	}
' "$vibrator_rc" > "$vibrator_rc_next"; then
	exit 1
fi

if ! awk -v rc_file="$vibrator_rc" -v motor_type="$motor_type" '
	function trim(value) {
		sub(/^[[:space:]]*/, "", value)
		sub(/[[:space:]]*$/, "", value)
		return value
	}
	{
		stripped = trim($0)
		if ($0 !~ /^[[:space:]]/ && stripped !~ /^#/ && stripped != "") {
			if (stripped ~ /^on[[:space:]]+/) {
				action = stripped
			} else {
				action = ""
			}
		}
		if (stripped ~ /^setprop[[:space:]]+sys\.haptic\.motor([[:space:]]+|$)/) {
			field_count = split(stripped, fields, /[[:space:]]+/)
			if (field_count == 3 && fields[3] == motor_type && action == "on property:sys.boot_completed=1") {
				exact++
			} else {
				invalid = 1
			}
		}
	}
	END {
		if (exact != 1 || invalid) {
			printf "! 修改后的线性震动启动设置无效：%s\n", rc_file > "/dev/stderr"
			exit 1
		}
	}
' "$vibrator_rc_next"; then
	exit 1
fi

_install_generated_file "$target_build_prop_next" "$target_build_prop"
_install_generated_file "$vibrator_rc_next" "$vibrator_rc"

std_print "✅ 已合并 $haptic_prop_count 项 sys.haptic 属性：odm/etc/build.prop"
std_print "✅ 已确保目标中不保留静态属性：sys.haptic.motor、sys.haptic.version"
std_print "✅ 已配置开机完成后设置 sys.haptic.motor=$motor_type：odm/etc/init/vibrator-default.rc"
std_print "处理完成"
