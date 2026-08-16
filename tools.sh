#!/bin/bash

_port_tools_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

std_print() {
	printf '> %s\n' "$*"
}

err_print() {
	printf '! %s\n' "$*" >&2
}

skip_print() {
	printf '> SKIP: %s\n' "$*"
}

_resolve_dna_config_dir() {
	local requested_project_dir="${1:-}"
	local candidate
	local -a config_candidates=()

	if [[ -z "$requested_project_dir" ]]; then
		err_print "未指定项目目录，无法获取 D.N.A 配置目录"
		return 1
	fi
	for candidate in "$requested_project_dir"/*_config; do
		if [[ -d "$candidate" ]]; then
			config_candidates+=("$candidate")
		fi
	done

	case "${#config_candidates[@]}" in
		0)
			err_print "项目目录缺少 D.N.A 配置目录（*_config）：$requested_project_dir"
			return 1
			;;
		1)
			(cd -- "${config_candidates[0]}" && pwd -P)
			;;
		*)
			err_print "项目目录存在多个 D.N.A 配置目录，无法确定：$requested_project_dir"
			for candidate in "${config_candidates[@]}"; do
				err_print "  $(basename -- "$candidate")"
			done
			return 1
			;;
	esac
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
	dna_config_dir="$(_resolve_dna_config_dir "$project_dir")" || return 1
	port_dir="$_port_tools_dir"
	export project_dir dna_config_dir
}

get_dna_config_dir() {
	if [[ -z "${project_dir:-}" ]]; then
		err_print "获取 D.N.A 配置目录前必须先调用 init_port_env"
		return 1
	fi
	if [[ -n "${dna_config_dir:-}" && -d "$dna_config_dir" ]]; then
		printf '%s\n' "$dna_config_dir"
		return 0
	fi

	dna_config_dir="$(_resolve_dna_config_dir "$project_dir")" || return 1
	export dna_config_dir
	printf '%s\n' "$dna_config_dir"
}

get_dna_config_path() {
	local relative_path="${1:-}"

	if ! _is_safe_relative_path "$relative_path"; then
		err_print "无效的 D.N.A 配置相对路径：$relative_path"
		return 1
	fi
	get_dna_config_dir >/dev/null || return 1
	printf '%s/%s\n' "$dna_config_dir" "$relative_path"
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

	_validate_part_name "$part_name" || return 1
	printf '%s_contexts.txt\n' "$part_name"
}

get_part_contexts_path() {
	local contexts_name

	contexts_name="$(get_part_contexts_name "${1:-}")" || return 1
	get_dna_config_path "$contexts_name"
}

get_part_fsconfig_name() {
	local part_name="${1:-}"
	local name_template="${FSCONFIG_NAME_TEMPLATE:-}"
	local fsconfig_name

	_validate_part_name "$part_name" || return 1
	if [[ -z "$name_template" ]]; then
		name_template='{part}_fsconfig.txt'
	fi
	if [[ "$name_template" != *'{part}'* ]]; then
		err_print "FSCONFIG_NAME_TEMPLATE 必须包含 {part}：$name_template"
		return 1
	fi

	fsconfig_name="${name_template//\{part\}/$part_name}"
	if ! _is_safe_relative_path "$fsconfig_name"; then
		err_print "生成的 fsconfig 文件名无效：$fsconfig_name"
		return 1
	fi
	printf '%s\n' "$fsconfig_name"
}

get_part_fsconfig_path() {
	local fsconfig_name

	fsconfig_name="$(get_part_fsconfig_name "${1:-}")" || return 1
	get_dna_config_path "$fsconfig_name"
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

_build_translated_contexts() {
	local source_contexts="${1:-}"
	local manifest_file="${2:-}"
	local source_prefix="${3:-}"
	local target_prefix="${4:-}"
	local generated_file="${5:-}"

	check_file_exists "$source_contexts" || return 1
	check_file_exists "$manifest_file" || return 1
	if [[ ! "$source_prefix" =~ ^/[A-Za-z0-9_.-]+$ || ! "$target_prefix" =~ ^/[A-Za-z0-9_.-]+$ ]]; then
		err_print "contexts 分区前缀无效：$source_prefix → $target_prefix"
		return 1
	fi
	_validate_marked_partition_mapping "${source_prefix#/}" "${target_prefix#/}" || return 1
	if [[ -z "$generated_file" ]]; then
		err_print "未指定 contexts 生成文件"
		return 1
	fi

	if ! awk \
		-v manifest="$manifest_file" \
		-v source_prefix="$source_prefix" \
		-v target_prefix="$target_prefix" \
		-v generated="$generated_file" '
		function normalize_path(value) {
			gsub(/\\/, "", value)
			return value
		}
		BEGIN {
			while ((getline manifest_line < manifest) > 0) {
				sub(/\r$/, "", manifest_line)
				if (manifest_line ~ /^[[:space:]]*(#|$)/) {
					continue
				}
				field_count = split(manifest_line, fields, /[[:space:]]+/)
				if (field_count < 2 || (fields[1] != "replace" && fields[1] != "missing")) {
					invalid_manifest = 1
					continue
				}
				wanted[normalize_path(source_prefix "/" fields[2])] = 1
				expected++
			}
			close(manifest)
		}
		{
			path = normalize_path($1)
			if (!(path in wanted)) {
				next
			}
			line = $0
			if (index(line, source_prefix) != 1) {
				next
			}
			line = target_prefix substr(line, length(source_prefix) + 1)
			found[path] = 1
			if (!(line in emitted)) {
				print line >> generated
				emitted[line] = 1
			}
		}
		END {
			missing = 0
			for (path in wanted) {
				if (!(path in found)) {
					missing++
				}
			}
			if (invalid_manifest || expected == 0 || missing > 0) {
				exit 1
			}
		}
	' "$source_contexts"; then
		err_print "无法从原包 contexts 生成目标路径映射：$source_contexts"
		return 1
	fi
}

validate_translated_contexts() {
	local source_contexts="${1:-}"
	local manifest_file="${2:-}"
	local source_prefix="${3:-}"
	local target_prefix="${4:-}"
	local temporary_file

	temporary_file="$(mktemp)" || return 1
	if ! _build_translated_contexts \
		"$source_contexts" "$manifest_file" "$source_prefix" "$target_prefix" "$temporary_file"; then
		rm -f -- "$temporary_file"
		return 1
	fi
	rm -f -- "$temporary_file"
}

merge_translated_contexts() {
	local source_contexts="${1:-}"
	local destination_contexts="${2:-}"
	local source_prefix="${3:-}"
	local target_prefix="${4:-}"
	local manifest_file="${5:-}"
	local generated_file
	local temporary_file

	check_file_exists "$destination_contexts" || return 1
	generated_file="$(mktemp "${destination_contexts}.source.XXXXXX")" || return 1
	temporary_file="$(mktemp "${destination_contexts}.tmp.XXXXXX")" || {
		rm -f -- "$generated_file"
		return 1
	}
	if ! _build_translated_contexts \
		"$source_contexts" "$manifest_file" "$source_prefix" "$target_prefix" "$generated_file"; then
		rm -f -- "$generated_file" "$temporary_file"
		return 1
	fi

	if ! awk -v generated="$generated_file" '
		function normalize_path(value) {
			gsub(/\\/, "", value)
			return value
		}
		function emit_replacements(path, replacement_index) {
			for (replacement_index = 1; replacement_index <= replacement_count[path]; replacement_index++) {
				print replacement[path, replacement_index]
			}
			emitted[path] = 1
		}
		BEGIN {
			while ((getline generated_line < generated) > 0) {
				generated_field_count = split(generated_line, generated_fields, /[[:space:]]+/)
				if (generated_field_count == 0) {
					continue
				}
				path = normalize_path(generated_fields[1])
				if (!(path in has_replacement)) {
					has_replacement[path] = 1
					order[++order_count] = path
				}
				replacement[path, ++replacement_count[path]] = generated_line
			}
			close(generated)
		}
		{
			path = normalize_path($1)
			if (path in has_replacement) {
				if (!(path in emitted)) {
					emit_replacements(path)
				}
				next
			}
			print
		}
		END {
			for (order_index = 1; order_index <= order_count; order_index++) {
				path = order[order_index]
				if (!(path in emitted)) {
					emit_replacements(path)
				}
			}
		}
	' "$destination_contexts" > "$temporary_file"; then
		rm -f -- "$generated_file" "$temporary_file"
		return 1
	fi
	chmod --reference="$destination_contexts" -- "$temporary_file" || {
		rm -f -- "$generated_file" "$temporary_file"
		return 1
	}
	rm -f -- "$generated_file"
	_install_generated_file "$temporary_file" "$destination_contexts"
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
