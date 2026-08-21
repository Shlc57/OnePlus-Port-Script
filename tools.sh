#!/bin/bash

_port_tools_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
_port_device_identity_project=""

declare -a _port_config_profiles=(
	DNA_config
	config
)
declare -A _port_contexts_name_templates=(
	[DNA_config]='{part}_contexts.txt'
	[config]='{part}_file_contexts'
)
declare -A _port_fsconfig_name_templates=(
	[DNA_config]='{part}_fsconfig.txt'
	[config]='{part}_fs_config'
)

std_print() {
	printf '> %s\n' "$*"
}

err_print() {
	printf '! %s\n' "$*" >&2
}

warn_print() {
	printf '! WARN: %s\n' "$*" >&2
}

skip_print() {
	printf '> SKIP: %s\n' "$*"
}

_resolve_config_profile() {
	local requested_project_dir="${1:-}"
	local profile

	if [[ -z "$requested_project_dir" ]]; then
		err_print "未指定项目目录，无法获取配置目录"
		return 1
	fi
	for profile in "${_port_config_profiles[@]}"; do
		if [[ -d "$requested_project_dir/$profile" ]]; then
			printf '%s\n' "$profile"
			return 0
		fi
	done

	err_print "项目目录缺少受支持的配置目录（DNA_config 或 config）：$requested_project_dir"
	return 1
}

_load_config_profile() {
	local requested_project_dir="${1:-}"
	local resolved_profile

	resolved_profile="$(_resolve_config_profile "$requested_project_dir")" || return 1
	config_profile="$resolved_profile"
	config_dir="$(cd -- "$requested_project_dir/$config_profile" && pwd -P)" || return 1
	contexts_name_template="${_port_contexts_name_templates[$config_profile]}"
	fsconfig_name_template="${_port_fsconfig_name_templates[$config_profile]}"
	export config_profile config_dir contexts_name_template fsconfig_name_template
}

init_port_env() {
	local requested_project_dir="${1:-}"

	if [[ -z "$requested_project_dir" ]]; then
		requested_project_dir="${project_dir:-$_port_tools_dir/..}"
	fi
	if [[ ! -d "$requested_project_dir" ]]; then
		err_print "项目目录不存在：$requested_project_dir"
		return 1
	fi

	project_dir="$(cd -- "$requested_project_dir" && pwd -P)"
	_load_config_profile "$project_dir" || return 1
	port_dir="$_port_tools_dir"
	export project_dir port_dir
	if [[ "$_port_device_identity_project" != "$project_dir" ]]; then
		_port_detect_device_identities "$project_dir" || return 1
	fi
}

get_config_dir() {
	if [[ -z "${project_dir:-}" ]]; then
		err_print "获取配置目录前必须先调用 init_port_env"
		return 1
	fi
	if [[ -n "${config_dir:-}" && -n "${config_profile:-}" && \
		-d "$config_dir" && \
		"${_port_contexts_name_templates[$config_profile]+present}" == present && \
		"${_port_fsconfig_name_templates[$config_profile]+present}" == present ]]; then
		printf '%s\n' "$config_dir"
		return 0
	fi

	_load_config_profile "$project_dir" || return 1
	printf '%s\n' "$config_dir"
}

get_config_path() {
	local relative_path="${1:-}"

	if ! _is_safe_relative_path "$relative_path"; then
		err_print "无效的配置相对路径：$relative_path"
		return 1
	fi
	get_config_dir >/dev/null || return 1
	printf '%s/%s\n' "$config_dir" "$relative_path"
}

check_part_exists() {
	local part_name="${1:-}"

	if [[ -z "$part_name" ]]; then
		err_print "未指定分区名称"
		return 1
	fi
	if [[ -z "${project_dir:-}" ]]; then
		err_print "检查分区前必须先调用 init_port_env"
		return 1
	fi
	if [[ ! -d "$project_dir/$part_name" ]]; then
		err_print "还未分解分区：$part_name"
		return 1
	fi
}

check_file_exists() {
	local file_path="${1:-}"
	local display_name="${2:-$file_path}"

	if [[ -z "$file_path" ]]; then
		err_print "未指定文件路径"
		return 1
	fi
	if [[ ! -f "$file_path" ]]; then
		err_print "文件不存在：$display_name"
		return 1
	fi
}

_validate_part_name() {
	local part_name="${1:-}"

	if [[ -z "$part_name" || "$part_name" == *[!A-Za-z0-9_.-]* ]]; then
		err_print "无效的分区名称：$part_name"
		return 1
	fi
}

get_part_contexts_name() {
	local part_name="${1:-}"
	local contexts_name

	_validate_part_name "$part_name" || return 1
	if [[ -z "${contexts_name_template:-}" || "$contexts_name_template" != *'{part}'* ]]; then
		err_print "contexts 名称模板无效：${contexts_name_template:-<空>}"
		return 1
	fi
	contexts_name="${contexts_name_template//\{part\}/$part_name}"
	if ! _is_safe_relative_path "$contexts_name"; then
		err_print "生成的 contexts 文件名无效：$contexts_name"
		return 1
	fi
	printf '%s\n' "$contexts_name"
}

get_part_contexts_path() {
	local contexts_name

	contexts_name="$(get_part_contexts_name "${1:-}")" || return 1
	get_config_path "$contexts_name"
}

get_part_fsconfig_name() {
	local part_name="${1:-}"
	local fsconfig_name

	_validate_part_name "$part_name" || return 1
	if [[ -z "${fsconfig_name_template:-}" || "$fsconfig_name_template" != *'{part}'* ]]; then
		err_print "fsconfig 名称模板无效：${fsconfig_name_template:-<空>}"
		return 1
	fi

	fsconfig_name="${fsconfig_name_template//\{part\}/$part_name}"
	if ! _is_safe_relative_path "$fsconfig_name"; then
		err_print "生成的 fsconfig 文件名无效：$fsconfig_name"
		return 1
	fi
	printf '%s\n' "$fsconfig_name"
}

get_part_fsconfig_path() {
	local fsconfig_name

	fsconfig_name="$(get_part_fsconfig_name "${1:-}")" || return 1
	get_config_path "$fsconfig_name"
}

_check_prop_args() {
	local file_path="${1:-}"
	local prop_key="${2:-}"

	check_file_exists "$file_path" || return 1
	if [[ -L "$file_path" ]]; then
		err_print "不支持直接修改符号链接：$file_path"
		return 1
	fi
	if [[ -z "$prop_key" || "$prop_key" == *'='* || "$prop_key" == *[[:space:]]* ]]; then
		err_print "无效的属性名：$prop_key"
		return 1
	fi
}

read_prop_value() {
	local prop_key="${1:-}"
	shift || true
	local prop_files=("$@")
	local prop_file
	local prop_value
	local awk_status

	if [[ -z "$prop_key" || "$prop_key" == *'='* || "$prop_key" == *[[:space:]]* ]]; then
		err_print "无效的属性名：$prop_key"
		return 1
	fi
	if (( ${#prop_files[@]} == 0 )); then
		err_print "读取属性时未指定来源文件：$prop_key"
		return 1
	fi
	for prop_file in "${prop_files[@]}"; do
		check_file_exists "$prop_file" || return 1
		if [[ -L "$prop_file" ]]; then
			err_print "不支持从符号链接读取属性：$prop_file"
			return 1
		fi
	done

	# 属性名通过环境变量传入 awk，单引号脚本中不应做 Shell 展开。
	# shellcheck disable=SC2016
	prop_value="$(env PORT_PROP_KEY="$prop_key" awk '
		BEGIN {
			key = ENVIRON["PORT_PROP_KEY"]
		}
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
			candidate_key = trim(substr(candidate, 1, separator - 1))
			if (candidate_key != key) {
				next
			}
			if (seen_in_file[FILENAME]++) {
				duplicate = 1
			}
			value = trim(substr(candidate, separator + 1))
			found = 1
		}
		END {
			if (duplicate) {
				exit 21
			}
			if (!found) {
				exit 20
			}
			print value
		}
	' "${prop_files[@]}")" || {
		awk_status=$?
		case "$awk_status" in
			20)
				err_print "来源属性不存在：$prop_key"
				;;
			21)
				err_print "来源文件内属性重复：$prop_key"
				;;
			*)
				err_print "读取来源属性失败：$prop_key"
				;;
		esac
		return 1
	}
	printf '%s\n' "$prop_value"
}

# 设备身份只在首个补丁修改工作树前识别一次并导出。后续 apply.sh 及其子脚本
# 统一消费同一份快照，不再重新读取可能已经被补丁修改过的 odm/build.prop。
_port_identity_pick_field() {
	local field="${1:-}"
	shift || true
	local key
	local prop_file
	local prop_value
	local grep_status
	local output_var="_port_identity_${field}"

	printf -v "$output_var" '%s' ''
	# 候选文件顺序代表来源优先级；先在高优先级文件内按属性语义回退，
	# 再读取下一份文件，避免低优先级分区中的 ro.product.odm.* 抢先覆盖。
	for prop_file in "${_port_identity_candidate_files[@]}"; do
		if [[ -L "$prop_file" ]]; then
			err_print "设备身份来源不能是符号链接：$prop_file"
			return 1
		elif [[ ! -e "$prop_file" ]]; then
			continue
		elif [[ ! -f "$prop_file" ]]; then
			err_print "设备身份来源不是普通文件：$prop_file"
			return 1
		fi
		for key in "$@"; do
			if grep -Eq "^[[:space:]]*${key//./\\.}[[:space:]]*=" "$prop_file"; then
				prop_value="$(read_prop_value "$key" "$prop_file")" || return 1
				if [[ -z "$prop_value" ]]; then
					err_print "设备身份属性值为空：$key（$prop_file）"
					return 1
				fi
				printf -v "$output_var" '%s' "$prop_value"
				return 0
			else
				grep_status=$?
				if (( grep_status > 1 )); then
					err_print "读取设备身份来源失败：$prop_file"
					return 1
				fi
			fi
		done
	done
	return 0
}

_port_identity_validate_component() {
	local component_name="${1:-}"
	local component_value="${2:-}"

	if [[ -z "$component_value" ]]; then
		return 0
	fi
	if [[ "$component_value" == "." || "$component_value" == ".." || \
		! "$component_value" =~ ^[A-Za-z0-9_.-]+$ ]]; then
		err_print "${component_name}无效：$component_value"
		return 1
	fi
}

_port_collect_base_identity_files() {
	local odm_build_prop="$project_dir/odm/build.prop"
	local profile_name=""
	local profile_candidate
	local -a discovered_profiles=()

	_port_identity_candidate_files=()
	if [[ -L "$odm_build_prop" ]]; then
		err_print "底包设备身份来源不能是符号链接：$odm_build_prop"
		return 1
	fi
	if [[ -f "$odm_build_prop" ]] && \
		grep -Eq '^[[:space:]]*ro\.separate\.soft[[:space:]]*=' "$odm_build_prop"; then
		profile_name="$(read_prop_value ro.separate.soft "$odm_build_prop")" || return 1
		_port_identity_validate_component "底包配置标识" "$profile_name" || return 1
		for profile_candidate in \
			"$project_dir/odm/etc/$profile_name/build.default.prop" \
			"$project_dir/odm/etc/$profile_name/build.prop"; do
			if [[ -e "$profile_candidate" || -L "$profile_candidate" ]]; then
				_port_identity_candidate_files+=("$profile_candidate")
			fi
		done
	fi

	# 非 Oplus 底包不一定提供 ro.separate.soft；仅在候选唯一时采用嵌套
	# build.default.prop，避免多机型底包中随意挑选配置。
	if (( ${#_port_identity_candidate_files[@]} == 0 )) && \
		[[ -d "$project_dir/odm/etc" && ! -L "$project_dir/odm/etc" ]]; then
		mapfile -t discovered_profiles < <(
			find "$project_dir/odm/etc" -mindepth 2 -maxdepth 2 \
				-type f -name build.default.prop -print | LC_ALL=C sort
		)
		if (( ${#discovered_profiles[@]} == 1 )); then
			_port_identity_candidate_files+=("${discovered_profiles[0]}")
		fi
	fi

	_port_identity_candidate_files+=(
		"$project_dir/odm/build.prop"
		"$project_dir/odm/etc/build.prop"
		"$project_dir/vendor/build.prop"
	)
}

_port_detect_identity_role() {
	local role="${1:-}"
	local role_prefix
	local identity_label
	local fingerprint_device=""
	local fingerprint_product=""
	local -a _port_identity_candidate_files=()
	local _port_identity_code=""
	local _port_identity_name=""
	local _port_identity_model=""
	local _port_identity_market_name=""
	local _port_identity_fingerprint=""

	case "$role" in
		base)
			role_prefix=BASE
			identity_label=底包
			_port_collect_base_identity_files || return 1
			_port_identity_pick_field code \
				ro.product.device \
				ro.vendor.product.device.oem \
				ro.product.odm.device \
				ro.product.vendor.device \
				ro.vendor.product.device \
				ro.build.product || return 1
			_port_identity_pick_field name \
				ro.product.name \
				ro.product.odm.name \
				ro.product.vendor.name \
				ro.vendor.product.name || return 1
			_port_identity_pick_field model \
				ro.product.model \
				ro.product.odm.model \
				ro.product.vendor.model \
				ro.vendor.product.model \
				ro.vendor.product.oem || return 1
			_port_identity_pick_field market_name \
				ro.product.vendor.marketname \
				ro.product.odm.marketname \
				ro.product.marketname || return 1
			_port_identity_pick_field fingerprint \
				ro.vendor.build.fingerprint \
				ro.odm.build.fingerprint \
				ro.product.build.fingerprint || return 1
			;;
		source)
			role_prefix=SOURCE
			identity_label=原包
			_port_identity_candidate_files=(
				"$project_dir/mi_odm/etc/build.prop"
				"$project_dir/mi_odm/build.prop"
				"$project_dir/product/etc/build.prop"
				"$project_dir/product/build.prop"
				"$project_dir/system/system/build.prop"
			)
			_port_identity_pick_field code \
				ro.product.odm.device \
				ro.product.vendor.device \
				ro.product.product.device \
				ro.product.device \
				ro.build.product || return 1
			_port_identity_pick_field name \
				ro.product.odm.name \
				ro.product.vendor.name \
				ro.product.product.name \
				ro.product.name || return 1
			_port_identity_pick_field model \
				ro.product.odm.model \
				ro.product.vendor.model \
				ro.product.product.model \
				ro.product.model || return 1
			_port_identity_pick_field market_name \
				ro.product.odm.marketname \
				ro.product.vendor.marketname \
				ro.product.product.marketname \
				ro.product.marketname || return 1
			_port_identity_pick_field fingerprint \
				ro.odm.build.fingerprint \
				ro.vendor.build.fingerprint \
				ro.product.build.fingerprint || return 1
			;;
		*)
			err_print "未知的设备身份来源：$role"
			return 1
			;;
	esac

	# 少数分区只提供 fingerprint；其中第三段为设备代号，第二段为产品名。
	if [[ -z "${_port_identity_code:-}" && -n "${_port_identity_fingerprint:-}" ]]; then
		fingerprint_device="$(awk -F/ 'NF >= 3 { print $3; exit }' <<< "$_port_identity_fingerprint")"
		fingerprint_product="$(awk -F/ 'NF >= 2 { print $2; exit }' <<< "$_port_identity_fingerprint")"
		fingerprint_device="${fingerprint_device%%:*}"
		fingerprint_product="${fingerprint_product%%:*}"
		_port_identity_code="${fingerprint_device:-$fingerprint_product}"
	fi
	if [[ -z "${_port_identity_name:-}" ]]; then
		_port_identity_name="${_port_identity_code:-}"
	fi
	if [[ -z "${_port_identity_market_name:-}" ]]; then
		_port_identity_market_name="${_port_identity_model:-${_port_identity_name:-}}"
	fi

	_port_identity_validate_component "${identity_label}设备代号" "${_port_identity_code:-}" || return 1

	printf -v "PORT_${role_prefix}_DEVICE_CODE" '%s' "${_port_identity_code:-}"
	printf -v "PORT_${role_prefix}_DEVICE_NAME" '%s' "${_port_identity_name:-}"
	printf -v "PORT_${role_prefix}_DEVICE_MODEL" '%s' "${_port_identity_model:-}"
	printf -v "PORT_${role_prefix}_DEVICE_MARKET_NAME" '%s' "${_port_identity_market_name:-}"
}

_port_export_device_identities() {
	PORT_SOURCE_DEVICE_FEATURE_FILE=""
	if [[ -n "$PORT_SOURCE_DEVICE_CODE" ]]; then
		PORT_SOURCE_DEVICE_FEATURE_FILE="$project_dir/product/etc/device_features/$PORT_SOURCE_DEVICE_CODE.xml"
	fi

	export \
		PORT_BASE_DEVICE_CODE PORT_BASE_DEVICE_NAME PORT_BASE_DEVICE_MODEL \
		PORT_BASE_DEVICE_MARKET_NAME \
		PORT_SOURCE_DEVICE_CODE PORT_SOURCE_DEVICE_NAME PORT_SOURCE_DEVICE_MODEL \
		PORT_SOURCE_DEVICE_MARKET_NAME PORT_SOURCE_DEVICE_FEATURE_FILE
}

_port_detect_device_identities() {
	local identity_project_dir="${1:-}"

	if [[ -z "$identity_project_dir" || "$identity_project_dir" != "$project_dir" ]]; then
		err_print "设备身份识别项目目录无效：$identity_project_dir"
		return 1
	fi

	# 每次切换工程时清空旧值。允许缺少可选分区；需要具体身份的补丁自行判断
	# 空值是否可用。
	PORT_BASE_DEVICE_CODE=""
	PORT_BASE_DEVICE_NAME=""
	PORT_BASE_DEVICE_MODEL=""
	PORT_BASE_DEVICE_MARKET_NAME=""
	PORT_SOURCE_DEVICE_CODE=""
	PORT_SOURCE_DEVICE_NAME=""
	PORT_SOURCE_DEVICE_MODEL=""
	PORT_SOURCE_DEVICE_MARKET_NAME=""

	_port_detect_identity_role base || return 1
	_port_detect_identity_role source || return 1
	_port_export_device_identities

	if [[ -n "$PORT_BASE_DEVICE_CODE" || -n "$PORT_BASE_DEVICE_NAME" ]]; then
		std_print "识别底包设备：${PORT_BASE_DEVICE_MARKET_NAME:-${PORT_BASE_DEVICE_NAME:-未知}}（代号：${PORT_BASE_DEVICE_CODE:-未知}）"
	else
		warn_print "移植前未识别到底包设备（请确认 vendor/odm 已解包）"
	fi
	if [[ -n "$PORT_SOURCE_DEVICE_CODE" || -n "$PORT_SOURCE_DEVICE_NAME" ]]; then
		std_print "识别原包设备：${PORT_SOURCE_DEVICE_MARKET_NAME:-${PORT_SOURCE_DEVICE_NAME:-未知}}（代号：${PORT_SOURCE_DEVICE_CODE:-未知}）"
	else
		warn_print "移植前未识别到原包设备（请确认 mi_odm/product 已解包）"
	fi
	_port_device_identity_project="$identity_project_dir"
}

validate_prop_file() {
	local prop_file="${1:-}"

	check_file_exists "$prop_file" || return 1
	if [[ -L "$prop_file" ]]; then
		err_print "属性覆盖文件不能是符号链接：$prop_file"
		return 1
	fi
	if ! awk -v prop_file="$prop_file" '
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
				printf "! 属性覆盖文件第 %d 行缺少等号：%s\n", NR, prop_file > "/dev/stderr"
				invalid = 1
				next
			}
			key = trim(substr(candidate, 1, separator - 1))
			if (key !~ /^[A-Za-z0-9_.-]+$/) {
				printf "! 属性覆盖文件第 %d 行属性名无效：%s\n", NR, prop_file > "/dev/stderr"
				invalid = 1
				next
			}
			if (key in seen) {
				printf "! 属性覆盖文件存在重复属性 %s：%s\n", key, prop_file > "/dev/stderr"
				invalid = 1
				next
			}
			seen[key] = 1
			count++
		}
		END {
			if (count == 0) {
				printf "! 属性覆盖文件没有有效属性：%s\n", prop_file > "/dev/stderr"
				invalid = 1
			}
			exit(invalid ? 1 : 0)
		}
	' "$prop_file"; then
		return 1
	fi
}

merge_prop_file() {
	local source_file="${1:-}"
	local target_file="${2:-}"
	local temporary_file

	validate_prop_file "$source_file" || return 1
	check_file_exists "$target_file" || return 1
	if [[ -L "$target_file" ]]; then
		err_print "不支持直接修改符号链接：$target_file"
		return 1
	fi

	temporary_file="$(mktemp "${target_file}.tmp.XXXXXX")" || return 1
	if ! awk -v source_file="$source_file" '
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
			while ((getline source_line < source_file) > 0) {
				sub(/\r$/, "", source_line)
				source_candidate = source_line
				sub(/^[[:space:]]*/, "", source_candidate)
				if (source_candidate == "" || substr(source_candidate, 1, 1) == "#") {
					continue
				}
				source_separator = index(source_candidate, "=")
				source_key = trim(substr(source_candidate, 1, source_separator - 1))
				source_value[source_key] = trim(substr(source_candidate, source_separator + 1))
				source_order[++source_count] = source_key
			}
			close(source_file)
		}
		{
			key = line_key($0)
			if (key in source_value) {
				if (!(key in written)) {
					print key "=" source_value[key]
					written[key] = 1
				}
				next
			}
			print
		}
		END {
			for (source_index = 1; source_index <= source_count; source_index++) {
				key = source_order[source_index]
				if (!(key in written)) {
					print key "=" source_value[key]
				}
			}
		}
	' "$target_file" > "$temporary_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
	_install_generated_file "$temporary_file" "$target_file"
}

_install_generated_file() {
	local temporary_file="${1:-}"
	local target_file="${2:-}"

	if cmp -s -- "$temporary_file" "$target_file"; then
		rm -f -- "$temporary_file"
		return 0
	fi
	chmod --reference="$target_file" -- "$temporary_file" || {
		rm -f -- "$temporary_file"
		return 1
	}
	mv -f -- "$temporary_file" "$target_file"
}

ensure_prop() {
	local file_path="${1:-}"
	local prop_key="${2:-}"
	local prop_value="${3-}"
	local temporary_file

	_check_prop_args "$file_path" "$prop_key" || return 1
	temporary_file="$(mktemp "${file_path}.tmp.XXXXXX")" || return 1
	# 属性名和值通过环境变量传入 awk，单引号脚本中不应做 Shell 展开。
	# shellcheck disable=SC2016
	if ! env PORT_PROP_KEY="$prop_key" PORT_PROP_VALUE="$prop_value" awk '
		BEGIN {
			key = ENVIRON["PORT_PROP_KEY"]
			value = ENVIRON["PORT_PROP_VALUE"]
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
			candidate = substr(candidate, 1, separator - 1)
			sub(/[[:space:]]*$/, "", candidate)
			return candidate
		}
		{
			if (line_key($0) == key) {
				if (!written) {
					print key "=" value
					written = 1
				}
				next
			}
			print
		}
		END {
			if (!written) {
				print key "=" value
			}
		}
	' "$file_path" > "$temporary_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
	_install_generated_file "$temporary_file" "$file_path"
}

comment_prop() {
	local file_path="${1:-}"
	local prop_key="${2:-}"
	local temporary_file

	_check_prop_args "$file_path" "$prop_key" || return 1
	temporary_file="$(mktemp "${file_path}.tmp.XXXXXX")" || return 1
	# 属性名通过环境变量传入 awk，单引号脚本中不应做 Shell 展开。
	# shellcheck disable=SC2016
	if ! env PORT_PROP_KEY="$prop_key" awk '
		BEGIN {
			key = ENVIRON["PORT_PROP_KEY"]
		}
		function active_line_key(line, candidate, separator) {
			candidate = line
			sub(/^[[:space:]]*/, "", candidate)
			if (substr(candidate, 1, 1) == "#") {
				return ""
			}
			separator = index(candidate, "=")
			if (separator == 0) {
				return ""
			}
			candidate = substr(candidate, 1, separator - 1)
			sub(/[[:space:]]*$/, "", candidate)
			return candidate
		}
		{
			if (active_line_key($0) == key) {
				match($0, /^[[:space:]]*/)
				print substr($0, 1, RLENGTH) "#" substr($0, RLENGTH + 1)
				next
			}
			print
		}
	' "$file_path" > "$temporary_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
	_install_generated_file "$temporary_file" "$file_path"
}

append_unique_lines() {
	local source_file="${1:-}"
	local destination_file="${2:-}"
	local destination_dir
	local temporary_file

	check_file_exists "$source_file" || return 1
	if [[ -z "$destination_file" ]]; then
		err_print "未指定追加目标文件"
		return 1
	fi
	if [[ -d "$destination_file" || -L "$destination_file" ]]; then
		err_print "追加目标不是普通文件：$destination_file"
		return 1
	fi
	if [[ -e "$destination_file" && "$source_file" -ef "$destination_file" ]]; then
		return 0
	fi

	destination_dir="$(dirname -- "$destination_file")"
	mkdir -p -- "$destination_dir"
	temporary_file="$(mktemp "${destination_file}.tmp.XXXXXX")" || return 1
	if [[ -f "$destination_file" ]]; then
		# 目标路径通过环境变量传入 awk，单引号脚本中不应做 Shell 展开。
		# shellcheck disable=SC2016
		if ! env PORT_DESTINATION_FILE="$destination_file" awk '
			FILENAME == ENVIRON["PORT_DESTINATION_FILE"] {
				seen[$0] = 1
				print
				next
			}
			!($0 in seen) {
				seen[$0] = 1
				print
			}
		' "$destination_file" "$source_file" > "$temporary_file"; then
			rm -f -- "$temporary_file"
			return 1
		fi
		_install_generated_file "$temporary_file" "$destination_file"
	else
		if ! awk '!($0 in seen) { seen[$0] = 1; print }' "$source_file" > "$temporary_file"; then
			rm -f -- "$temporary_file"
			return 1
		fi
		chmod 0644 -- "$temporary_file"
		mv -f -- "$temporary_file" "$destination_file"
	fi
}

check_partition_metadata_tool() {
	local metadata_tool="$_port_tools_dir/partition_metadata.py"

	if ! command -v python3 >/dev/null 2>&1; then
		err_print "缺少 Python 3，无法处理分区 contexts/fsconfig"
		return 1
	fi
	check_file_exists "$metadata_tool" || return 1
	printf '%s\n' "$metadata_tool"
}

_partition_metadata_tool() {
	local metadata_tool

	metadata_tool="$(check_partition_metadata_tool)" || return 1
	python3 "$metadata_tool" "$@"
}

merge_contexts_file() {
	local patch_file="${1:-}"
	local destination_file="${2:-}"
	local patch_prefix="${3:-}"
	local -a command_args=(
		merge
		--kind contexts
		--patch "$patch_file"
		--target "$destination_file"
	)

	check_file_exists "$patch_file" || return 1
	check_file_exists "$destination_file" || return 1
	if [[ -n "$patch_prefix" ]]; then
		command_args+=(--patch-prefix "$patch_prefix")
	fi
	_partition_metadata_tool "${command_args[@]}"
}

merge_fsconfig_file() {
	local patch_file="${1:-}"
	local destination_file="${2:-}"
	local patch_prefix="${3:-}"
	local -a command_args=(
		merge
		--kind fsconfig
		--patch "$patch_file"
		--target "$destination_file"
	)

	check_file_exists "$patch_file" || return 1
	check_file_exists "$destination_file" || return 1
	if [[ -n "$patch_prefix" ]]; then
		command_args+=(--patch-prefix "$patch_prefix")
	fi
	_partition_metadata_tool "${command_args[@]}"
}

remove_contexts_prefix() {
	local contexts_file="${1:-}"
	local contexts_prefix="${2:-}"

	check_file_exists "$contexts_file" || return 1
	_partition_metadata_tool remove-prefix \
		--kind contexts \
		--target "$contexts_file" \
		--prefix "$contexts_prefix"
}

remove_fsconfig_prefix() {
	local fsconfig_file="${1:-}"
	local fsconfig_prefix="${2:-}"

	check_file_exists "$fsconfig_file" || return 1
	_partition_metadata_tool remove-prefix \
		--kind fsconfig \
		--target "$fsconfig_file" \
		--prefix "$fsconfig_prefix"
}

remove_part_metadata_prefix() {
	local part_name="${1:-}"
	local relative_path="${2:-}"
	local contexts_prefix
	local fsconfig_prefix

	_validate_part_name "$part_name" || return 1
	if [[ -n "$relative_path" ]] && ! _is_safe_relative_path "$relative_path"; then
		err_print "无效的分区元数据相对路径：$relative_path"
		return 1
	fi
	contexts_prefix="/$part_name"
	fsconfig_prefix="$part_name"
	if [[ -n "$relative_path" ]]; then
		contexts_prefix="${contexts_prefix}/${relative_path}"
		fsconfig_prefix="${fsconfig_prefix}/${relative_path}"
	fi
	remove_contexts_prefix "$(get_part_contexts_path "$part_name")" "$contexts_prefix" || return 1
	remove_fsconfig_prefix "$(get_part_fsconfig_path "$part_name")" "$fsconfig_prefix"
}

ensure_part_fsconfig_entry() {
	local part_name="${1:-}"
	local relative_path="${2:-}"
	local uid="${3:-}"
	local gid="${4:-}"
	local mode="${5:-}"
	shift 5 2>/dev/null || true
	local extra_fields=("$@")
	local patch_file
	local merge_status=0

	_validate_part_name "$part_name" || return 1
	if ! _is_safe_relative_path "$relative_path"; then
		err_print "无效的 fsconfig 相对路径：$relative_path"
		return 1
	fi
	if [[ ! "$uid" =~ ^[0-9]+$ || ! "$gid" =~ ^[0-9]+$ || ! "$mode" =~ ^0[0-7]{3,4}$ ]]; then
		err_print "无效的 fsconfig 权限：uid=$uid gid=$gid mode=$mode"
		return 1
	fi
	patch_file="$(mktemp "$(get_config_path '.fsconfig_entry.XXXXXX')")" || return 1
	{
		printf '%s/%s %s %s %s' "$part_name" "$relative_path" "$uid" "$gid" "$mode"
		if (( ${#extra_fields[@]} > 0 )); then
			printf ' %s' "${extra_fields[@]}"
		fi
		printf '\n'
	} > "$patch_file"
	merge_fsconfig_file "$patch_file" "$(get_part_fsconfig_path "$part_name")" || merge_status=$?
	rm -f -- "$patch_file"
	return "$merge_status"
}

copy_tree_missing_only() {
	local source_dir="${1:-}"
	local destination_dir="${2:-}"
	local source_path
	local destination_path
	local relative_path

	if [[ ! -d "$source_dir" || -L "$source_dir" ]]; then
		err_print "源目录不存在或不是普通目录：$source_dir"
		return 1
	fi
	if [[ -z "$destination_dir" ]]; then
		err_print "未指定目标目录"
		return 1
	fi
	if [[ -e "$destination_dir" && ( ! -d "$destination_dir" || -L "$destination_dir" ) ]]; then
		err_print "目标路径不是普通目录：$destination_dir"
		return 1
	fi

	source_dir="${source_dir%/}"
	destination_dir="${destination_dir%/}"
	while IFS= read -r -d '' source_path; do
		relative_path="${source_path#"$source_dir"/}"
		destination_path="$destination_dir/$relative_path"
		if [[ ! -e "$destination_path" && ! -L "$destination_path" ]]; then
			continue
		fi
		if [[ -L "$source_path" ]]; then
			if [[ ! -L "$destination_path" || "$(readlink -- "$source_path")" != "$(readlink -- "$destination_path" 2>/dev/null || true)" ]]; then
				err_print "目标已存在且符号链接不同：$destination_path"
				return 1
			fi
		elif [[ -d "$source_path" ]]; then
			if [[ ! -d "$destination_path" || -L "$destination_path" ]]; then
				err_print "目标已存在且类型不同：$destination_path"
				return 1
			fi
		elif [[ -f "$source_path" ]]; then
			if [[ ! -f "$destination_path" || -L "$destination_path" ]] || ! cmp -s -- "$source_path" "$destination_path"; then
				err_print "目标已存在且内容不同：$destination_path"
				return 1
			fi
		else
			err_print "不支持复制该文件类型：$source_path"
			return 1
		fi
	done < <(find "$source_dir" -mindepth 1 -print0)

	if [[ ! -d "$destination_dir" ]]; then
		mkdir -p -- "$destination_dir"
		chmod --reference="$source_dir" -- "$destination_dir"
	fi
	while IFS= read -r -d '' source_path; do
		relative_path="${source_path#"$source_dir"/}"
		destination_path="$destination_dir/$relative_path"
		if [[ -e "$destination_path" || -L "$destination_path" ]]; then
			continue
		fi
		if [[ -d "$source_path" && ! -L "$source_path" ]]; then
			mkdir -p -- "$destination_path"
			chmod --reference="$source_path" -- "$destination_path"
		else
			mkdir -p -- "$(dirname -- "$destination_path")"
			cp -a -- "$source_path" "$destination_path"
		fi
	done < <(find "$source_dir" -mindepth 1 -print0)
}

_is_safe_relative_path() {
	local relative_path="${1:-}"

	case "$relative_path" in
		""|/*|.|..|./*|*/./*|*/.|../*|*/../*|*/..|*//*|*/|*\\*|*[[:space:]]*)
			return 1
			;;
		*)
			return 0
			;;
	esac
}

load_selinux_bundle_manifest() {
	local manifest_file="${1:-}"
	local requested_bundle_dir="${2:-}"
	local bundle_dir
	local manifest_real_path
	local record_type
	local target_name
	local relative_path
	local extra_field
	local fragment_path
	local fragment_real_path
	local record_key
	local record_count=0
	declare -A seen_records=()

	SELINUX_BUNDLE_REQUIREMENTS=()
	SELINUX_BUNDLE_POLICY_FRAGMENTS=()
	SELINUX_BUNDLE_CONTEXT_TARGETS=()
	SELINUX_BUNDLE_CONTEXT_FRAGMENTS=()
	if [[ ! -d "$requested_bundle_dir" || -L "$requested_bundle_dir" ]]; then
		err_print "SELinux bundle 目录不存在或不是普通目录：$requested_bundle_dir"
		return 1
	fi
	bundle_dir="$(cd -- "$requested_bundle_dir" && pwd -P)" || return 1
	check_file_exists "$manifest_file" || return 1
	if [[ -L "$manifest_file" ]]; then
		err_print "SELinux bundle 清单不能是符号链接：$manifest_file"
		return 1
	fi
	manifest_real_path="$(realpath -e -- "$manifest_file")" || return 1
	case "$manifest_real_path" in
		"$bundle_dir"/*) ;;
		*)
			err_print "SELinux bundle 清单不属于声明目录：$manifest_file"
			return 1
			;;
	esac

	while IFS=$'\t' read -r record_type target_name relative_path extra_field || \
		[[ -n "$record_type" || -n "$target_name" || -n "$relative_path" ]]; do
		record_type="${record_type%$'\r'}"
		target_name="${target_name%$'\r'}"
		relative_path="${relative_path%$'\r'}"
		extra_field="${extra_field%$'\r'}"
		[[ -z "$record_type" || "$record_type" == \#* ]] && continue
		if [[ -z "$target_name" || -z "$relative_path" || -n "$extra_field" ]]; then
			err_print "SELinux bundle 清单格式错误：$manifest_file"
			return 1
		fi
		if ! _is_safe_relative_path "$relative_path"; then
			err_print "SELinux bundle 相对路径不安全：$relative_path"
			return 1
		fi
		record_key="$record_type:$target_name:$relative_path"
		if [[ -n "${seen_records[$record_key]+present}" ]]; then
			err_print "SELinux bundle 清单条目重复：$record_key"
			return 1
		fi
		seen_records["$record_key"]=1
		case "$record_type" in
			require)
				if [[ "$target_name" != project ]]; then
					err_print "SELinux bundle require 目标无效：$target_name"
					return 1
				fi
				SELINUX_BUNDLE_REQUIREMENTS+=("$relative_path")
				;;
			policy)
				if [[ "$target_name" != vendor_policy ]]; then
					err_print "SELinux bundle policy 目标无效：$target_name"
					return 1
				fi
				fragment_path="$bundle_dir/$relative_path"
				check_file_exists "$fragment_path" || return 1
				if [[ -L "$fragment_path" ]]; then
					err_print "SELinux bundle 片段不能是符号链接：$fragment_path"
					return 1
				fi
				fragment_real_path="$(realpath -e -- "$fragment_path")" || return 1
				case "$fragment_real_path" in
					"$bundle_dir"/*) ;;
					*)
						err_print "SELinux bundle 片段越出声明目录：$fragment_path"
						return 1
						;;
				esac
				SELINUX_BUNDLE_POLICY_FRAGMENTS+=("$fragment_real_path")
				;;
			contexts)
				if [[ ! "$target_name" =~ ^[a-z][a-z0-9_]*$ ]]; then
					err_print "SELinux bundle contexts 目标无效：$target_name"
					return 1
				fi
				fragment_path="$bundle_dir/$relative_path"
				check_file_exists "$fragment_path" || return 1
				if [[ -L "$fragment_path" ]]; then
					err_print "SELinux bundle 片段不能是符号链接：$fragment_path"
					return 1
				fi
				fragment_real_path="$(realpath -e -- "$fragment_path")" || return 1
				case "$fragment_real_path" in
					"$bundle_dir"/*) ;;
					*)
						err_print "SELinux bundle 片段越出声明目录：$fragment_path"
						return 1
						;;
				esac
				SELINUX_BUNDLE_CONTEXT_TARGETS+=("$target_name")
				SELINUX_BUNDLE_CONTEXT_FRAGMENTS+=("$fragment_real_path")
				;;
			*)
				err_print "SELinux bundle 清单类型无效：$record_type"
				return 1
				;;
		esac
		record_count=$((record_count + 1))
	done < "$manifest_file"

	if (( record_count == 0 || ${#SELINUX_BUNDLE_REQUIREMENTS[@]} == 0 )); then
		err_print "SELinux bundle 清单为空或缺少 require：$manifest_file"
		return 1
	fi
	if (( ${#SELINUX_BUNDLE_POLICY_FRAGMENTS[@]} == 0 && \
		${#SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]} == 0 )); then
		err_print "SELinux bundle 没有 policy 或 contexts 交付物：$manifest_file"
		return 1
	fi
}

check_selinux_bundle_requirements() {
	local requested_project_dir="${1:-}"
	local bundle_project_dir
	local requirement_path
	local target_path
	local target_parent
	local target_parent_real
	local present_count=0

	SELINUX_BUNDLE_ACTIVE=false
	if [[ ! -d "$requested_project_dir" ]]; then
		err_print "SELinux bundle 项目目录不存在：$requested_project_dir"
		return 1
	fi
	bundle_project_dir="$(cd -- "$requested_project_dir" && pwd -P)" || return 1
	if (( ${#SELINUX_BUNDLE_REQUIREMENTS[@]} == 0 )); then
		err_print "尚未加载 SELinux bundle require 清单"
		return 1
	fi
	for requirement_path in "${SELINUX_BUNDLE_REQUIREMENTS[@]}"; do
		if ! _is_safe_relative_path "$requirement_path"; then
			err_print "SELinux bundle 必需路径不安全：$requirement_path"
			return 1
		fi
		target_path="$bundle_project_dir/$requirement_path"
		target_parent="$(dirname -- "$target_path")"
		target_parent_real="$(realpath -m -- "$target_parent")" || return 1
		case "$target_parent_real" in
			"$bundle_project_dir"|"$bundle_project_dir"/*) ;;
			*)
				err_print "SELinux bundle 必需路径通过符号链接越出项目：$target_path"
				return 1
				;;
		esac
		if [[ -e "$target_path" || -L "$target_path" ]]; then
			present_count=$((present_count + 1))
			if [[ ! -f "$target_path" || -L "$target_path" ]]; then
				err_print "SELinux bundle 必需文件类型无效：$target_path"
				return 1
			fi
		fi
	done
	if (( present_count == 0 )); then
		return 0
	fi
	if (( present_count != ${#SELINUX_BUNDLE_REQUIREMENTS[@]} )); then
		err_print "SELinux bundle 必需文件不完整：${present_count}/${#SELINUX_BUNDLE_REQUIREMENTS[@]}"
		return 1
	fi
	# shellcheck disable=SC2034 # 该状态由调用方在同一 sourced shell 中消费。
	SELINUX_BUNDLE_ACTIVE=true
}

_validate_marked_partition_mapping() {
	local source_name="${1:-}"
	local target_name="${2:-}"
	local expected_target=""

	case "$target_name" in
		mi_odm|mi_vendor)
			err_print "来源标记目录不能作为最终目标分区：$target_name"
			return 1
			;;
	esac
	case "$source_name" in
		mi_odm)
			expected_target="odm"
			;;
		mi_vendor)
			expected_target="vendor"
			;;
	esac
	if [[ -n "$expected_target" && "$target_name" != "$expected_target" ]]; then
		err_print "来源标记 $source_name 只能映射到最终分区：$expected_target"
		return 1
	fi
}

validate_source_file_manifest() {
	local source_dir="${1:-}"
	local target_dir="${2:-}"
	local manifest_file="${3:-}"
	local operation
	local relative_path
	local extra_field
	local source_path
	local target_path
	local source_real_path
	local target_real_path
	local source_parent_real
	local target_parent_real
	local source_name
	local target_name
	local entry_count=0
	declare -A seen_paths=()

	if [[ ! -d "$source_dir" || -L "$source_dir" ]]; then
		err_print "原包来源目录不存在或不是普通目录：$source_dir"
		return 1
	fi
	if [[ ! -d "$target_dir" || -L "$target_dir" ]]; then
		err_print "最终目标分区不存在或不是普通目录：$target_dir"
		return 1
	fi
	source_real_path="$(realpath -- "$source_dir")" || return 1
	target_real_path="$(realpath -- "$target_dir")" || return 1
	if [[ "$source_real_path" == "$target_real_path" ]]; then
		err_print "原包来源目录不能同时作为最终目标分区：$source_dir"
		return 1
	fi
	source_name="$(basename -- "$source_real_path")"
	target_name="$(basename -- "$target_real_path")"
	_validate_marked_partition_mapping "$source_name" "$target_name" || return 1
	check_file_exists "$manifest_file" || return 1

	while IFS=$'\t' read -r operation relative_path extra_field || [[ -n "$operation" || -n "$relative_path" ]]; do
		operation="${operation%$'\r'}"
		relative_path="${relative_path%$'\r'}"
		extra_field="${extra_field%$'\r'}"
		if [[ -z "$operation" || "$operation" == \#* ]]; then
			continue
		fi
		if [[ -z "$relative_path" || -n "$extra_field" ]]; then
			err_print "来源清单格式错误：$manifest_file"
			return 1
		fi
		case "$operation" in
			replace|missing)
				;;
			*)
				err_print "来源清单操作无效：$operation"
				return 1
				;;
		esac
		if ! _is_safe_relative_path "$relative_path"; then
			err_print "来源清单路径不安全：$relative_path"
			return 1
		fi
		if [[ -n "${seen_paths[$relative_path]+present}" ]]; then
			err_print "来源清单存在重复路径：$relative_path"
			return 1
		fi
		seen_paths["$relative_path"]=1
		entry_count=$((entry_count + 1))

		source_path="$source_dir/$relative_path"
		target_path="$target_dir/$relative_path"
		source_parent_real="$(realpath -m -- "$(dirname -- "$source_path")")" || return 1
		target_parent_real="$(realpath -m -- "$(dirname -- "$target_path")")" || return 1
		case "$source_parent_real" in
			"$source_real_path"|"$source_real_path"/*) ;;
			*)
				err_print "原包来源路径通过符号链接越出分区：$source_path"
				return 1
				;;
		esac
		case "$target_parent_real" in
			"$target_real_path"|"$target_real_path"/*) ;;
			*)
				err_print "最终目标路径通过符号链接越出分区：$target_path"
				return 1
				;;
		esac
		if [[ ! -f "$source_path" && ! -L "$source_path" ]] || [[ -d "$source_path" && ! -L "$source_path" ]]; then
			err_print "原包来源文件不存在或不是普通文件：$source_path"
			return 1
		fi
		if [[ -d "$target_path" && ! -L "$target_path" ]]; then
			err_print "最终目标路径是目录，无法写入文件：$target_path"
			return 1
		fi
	done < "$manifest_file"

	if (( entry_count == 0 )); then
		err_print "来源清单为空：$manifest_file"
		return 1
	fi
}

copy_file_missing_only() {
	local source_file="${1:-}"
	local target_file="${2:-}"

	if [[ ! -f "$source_file" && ! -L "$source_file" ]] || [[ -d "$source_file" && ! -L "$source_file" ]]; then
		err_print "原包来源文件不存在或不是普通文件：$source_file"
		return 1
	fi
	if [[ -d "$target_file" && ! -L "$target_file" ]]; then
		err_print "最终目标路径是目录，无法写入文件：$target_file"
		return 1
	fi
	if [[ -e "$target_file" || -L "$target_file" ]]; then
		if [[ -L "$source_file" ]]; then
			if [[ ! -L "$target_file" || "$(readlink -- "$source_file")" != "$(readlink -- "$target_file" 2>/dev/null || true)" ]]; then
				err_print "最终目标已存在且符号链接不同：$target_file"
				return 1
			fi
		elif [[ ! -f "$target_file" || -L "$target_file" ]] || ! cmp -s -- "$source_file" "$target_file"; then
			err_print "最终目标已存在且内容不同：$target_file"
			return 1
		fi
		return 0
	fi

	mkdir -p -- "$(dirname -- "$target_file")"
	cp -a -- "$source_file" "$target_file"
}

apply_source_file_manifest() {
	local source_dir="${1:-}"
	local target_dir="${2:-}"
	local manifest_file="${3:-}"
	local operation
	local relative_path
	local extra_field
	local source_path
	local target_path

	validate_source_file_manifest "$source_dir" "$target_dir" "$manifest_file" || return 1
	while IFS=$'\t' read -r operation relative_path extra_field || [[ -n "$operation" || -n "$relative_path" ]]; do
		operation="${operation%$'\r'}"
		relative_path="${relative_path%$'\r'}"
		[[ -z "$operation" || "$operation" == \#* ]] && continue
		source_path="$source_dir/$relative_path"
		target_path="$target_dir/$relative_path"
		case "$operation" in
			replace)
				replace_file_if_different "$source_path" "$target_path" || return 1
				;;
			missing)
				copy_file_missing_only "$source_path" "$target_path" || return 1
				;;
		esac
	done < "$manifest_file"
}

_build_translated_manifest_metadata() {
	local source_metadata="${1:-}"
	local manifest_file="${2:-}"
	local source_prefix="${3:-}"
	local target_prefix="${4:-}"
	local generated_file="${5:-}"
	local metadata_kind="${6:-}"

	check_file_exists "$source_metadata" || return 1
	check_file_exists "$manifest_file" || return 1
	if [[ -z "$generated_file" ]]; then
		err_print "未指定 $metadata_kind 生成文件"
		return 1
	fi
	_partition_metadata_tool translate-manifest \
		--kind "$metadata_kind" \
		--source "$source_metadata" \
		--manifest "$manifest_file" \
		--source-prefix "$source_prefix" \
		--target-prefix "$target_prefix" \
		--output "$generated_file"
}

_build_translated_contexts() {
	_build_translated_manifest_metadata "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" contexts
}

_build_translated_fsconfig() {
	_build_translated_manifest_metadata "${1:-}" "${2:-}" "${3:-}" "${4:-}" "${5:-}" fsconfig
}

validate_translated_contexts() {
	local temporary_file
	local build_status=0

	temporary_file="$(mktemp)" || return 1
	_build_translated_contexts \
		"${1:-}" "${2:-}" "${3:-}" "${4:-}" "$temporary_file" || build_status=$?
	rm -f -- "$temporary_file"
	return "$build_status"
}

merge_translated_contexts() {
	local source_contexts="${1:-}"
	local destination_contexts="${2:-}"
	local source_prefix="${3:-}"
	local target_prefix="${4:-}"
	local manifest_file="${5:-}"
	local generated_file
	local merge_status=0

	check_file_exists "$destination_contexts" || return 1
	generated_file="$(mktemp "${destination_contexts}.source.XXXXXX")" || return 1
	if ! _build_translated_contexts \
		"$source_contexts" "$manifest_file" "$source_prefix" "$target_prefix" "$generated_file"; then
		rm -f -- "$generated_file"
		return 1
	fi
	merge_contexts_file "$generated_file" "$destination_contexts" || merge_status=$?
	rm -f -- "$generated_file"
	return "$merge_status"
}

validate_translated_fsconfig() {
	local temporary_file
	local build_status=0

	temporary_file="$(mktemp)" || return 1
	_build_translated_fsconfig \
		"${1:-}" "${2:-}" "${3:-}" "${4:-}" "$temporary_file" || build_status=$?
	rm -f -- "$temporary_file"
	return "$build_status"
}

merge_translated_fsconfig() {
	local source_fsconfig="${1:-}"
	local destination_fsconfig="${2:-}"
	local source_prefix="${3:-}"
	local target_prefix="${4:-}"
	local manifest_file="${5:-}"
	local generated_file
	local merge_status=0

	check_file_exists "$destination_fsconfig" || return 1
	generated_file="$(mktemp "${destination_fsconfig}.source.XXXXXX")" || return 1
	if ! _build_translated_fsconfig \
		"$source_fsconfig" "$manifest_file" "$source_prefix" "$target_prefix" "$generated_file"; then
		rm -f -- "$generated_file"
		return 1
	fi
	merge_fsconfig_file "$generated_file" "$destination_fsconfig" || merge_status=$?
	rm -f -- "$generated_file"
	return "$merge_status"
}

_build_translated_metadata_prefix() {
	local source_metadata="${1:-}"
	local source_prefix="${2:-}"
	local target_prefix="${3:-}"
	local generated_file="${4:-}"
	local metadata_kind="${5:-}"

	check_file_exists "$source_metadata" || return 1
	if [[ -z "$generated_file" ]]; then
		err_print "未指定 $metadata_kind 生成文件"
		return 1
	fi
	_partition_metadata_tool translate-prefix \
		--kind "$metadata_kind" \
		--source "$source_metadata" \
		--source-prefix "$source_prefix" \
		--target-prefix "$target_prefix" \
		--output "$generated_file"
}

validate_translated_contexts_prefix() {
	local temporary_file
	local build_status=0

	temporary_file="$(mktemp)" || return 1
	_build_translated_metadata_prefix \
		"${1:-}" "${2:-}" "${3:-}" "$temporary_file" contexts || build_status=$?
	rm -f -- "$temporary_file"
	return "$build_status"
}

validate_translated_fsconfig_prefix() {
	local temporary_file
	local build_status=0

	temporary_file="$(mktemp)" || return 1
	_build_translated_metadata_prefix \
		"${1:-}" "${2:-}" "${3:-}" "$temporary_file" fsconfig || build_status=$?
	rm -f -- "$temporary_file"
	return "$build_status"
}

merge_translated_contexts_prefix() {
	local source_contexts="${1:-}"
	local destination_contexts="${2:-}"
	local source_prefix="${3:-}"
	local target_prefix="${4:-}"
	local generated_file
	local merge_status=0

	check_file_exists "$destination_contexts" || return 1
	generated_file="$(mktemp "${destination_contexts}.source.XXXXXX")" || return 1
	if ! _build_translated_metadata_prefix \
		"$source_contexts" "$source_prefix" "$target_prefix" "$generated_file" contexts; then
		rm -f -- "$generated_file"
		return 1
	fi
	merge_contexts_file "$generated_file" "$destination_contexts" || merge_status=$?
	rm -f -- "$generated_file"
	return "$merge_status"
}

merge_translated_fsconfig_prefix() {
	local source_fsconfig="${1:-}"
	local destination_fsconfig="${2:-}"
	local source_prefix="${3:-}"
	local target_prefix="${4:-}"
	local generated_file
	local merge_status=0

	check_file_exists "$destination_fsconfig" || return 1
	generated_file="$(mktemp "${destination_fsconfig}.source.XXXXXX")" || return 1
	if ! _build_translated_metadata_prefix \
		"$source_fsconfig" "$source_prefix" "$target_prefix" "$generated_file" fsconfig; then
		rm -f -- "$generated_file"
		return 1
	fi
	merge_fsconfig_file "$generated_file" "$destination_fsconfig" || merge_status=$?
	rm -f -- "$generated_file"
	return "$merge_status"
}

merge_tree() {
	local source_dir="${1:-}"
	local destination_dir="${2:-}"

	if [[ ! -d "$source_dir" || -L "$source_dir" ]]; then
		err_print "源目录不存在或不是普通目录：$source_dir"
		return 1
	fi
	if [[ -z "$destination_dir" ]]; then
		err_print "未指定目标目录"
		return 1
	fi
	if [[ -e "$destination_dir" && ( ! -d "$destination_dir" || -L "$destination_dir" ) ]]; then
		err_print "目标路径不是普通目录：$destination_dir"
		return 1
	fi

	mkdir -p -- "$destination_dir"
	cp -a -- "$source_dir"/. "$destination_dir"/
}

replace_file_if_different() {
	local source_file="${1:-}"
	local destination_file="${2:-}"
	local destination_dir
	local destination_name
	local temporary_file

	if [[ ! -f "$source_file" && ! -L "$source_file" ]]; then
		err_print "源文件不存在：$source_file"
		return 1
	fi
	if [[ -z "$destination_file" || -d "$destination_file" ]]; then
		err_print "无效的目标文件：$destination_file"
		return 1
	fi
	if [[ -L "$source_file" && -L "$destination_file" && "$(readlink -- "$source_file")" == "$(readlink -- "$destination_file")" ]]; then
		return 0
	fi
	if [[ ! -L "$source_file" && ! -L "$destination_file" && -f "$destination_file" ]] && cmp -s -- "$source_file" "$destination_file"; then
		return 0
	fi

	destination_dir="$(dirname -- "$destination_file")"
	destination_name="$(basename -- "$destination_file")"
	mkdir -p -- "$destination_dir"
	temporary_file="$(mktemp "$destination_dir/.${destination_name}.tmp.XXXXXX")" || return 1
	rm -f -- "$temporary_file"
	if ! cp -a -- "$source_file" "$temporary_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
	if ! mv -fT -- "$temporary_file" "$destination_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
}

remove_path_if_exists() {
	local requested_path="${1:-}"
	local lexical_path
	local normalized_project_dir
	local resolved_parent
	local path_name
	local deletion_path

	if [[ -z "$requested_path" ]]; then
		err_print "拒绝删除空路径"
		return 1
	fi
	if [[ -z "${project_dir:-}" ]]; then
		err_print "删除前必须先调用 init_port_env"
		return 1
	fi

	lexical_path="$(realpath -m -s -- "$requested_path")" || return 1
	normalized_project_dir="$(realpath -m -- "$project_dir")" || return 1
	case "$lexical_path" in
		"$normalized_project_dir"/*) ;;
		*)
			err_print "拒绝删除项目目录之外的路径：$requested_path"
			return 1
			;;
	esac

	path_name="$(basename -- "$lexical_path")"
	if [[ "$path_name" == "." || "$path_name" == ".." ]]; then
		err_print "拒绝删除无效路径：$requested_path"
		return 1
	fi
	resolved_parent="$(realpath -m -- "$(dirname -- "$lexical_path")")" || return 1
	case "$resolved_parent" in
		"$normalized_project_dir"|"$normalized_project_dir"/*) ;;
		*)
			err_print "拒绝通过项目外的符号链接父目录删除：$requested_path"
			return 1
			;;
	esac
	deletion_path="$resolved_parent/$path_name"

	if [[ -e "$deletion_path" || -L "$deletion_path" ]]; then
		rm -rf -- "$deletion_path"
		std_print "已移除：${lexical_path#"$normalized_project_dir"/}"
	else
		skip_print "路径不存在：${lexical_path#"$normalized_project_dir"/}"
	fi
}
