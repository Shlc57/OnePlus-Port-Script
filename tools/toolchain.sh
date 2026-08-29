#!/usr/bin/env bash

# 特殊主机工具的唯一解析入口。local.properties 只保存本机绝对路径，
# 不应提交；未配置时只使用同名 PATH 命令，不探测 Snap、SDK 或用户目录。

_port_toolchain_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
_port_toolchain_root=$(cd -- "$_port_toolchain_dir/.." && pwd -P)
_port_toolchain_properties="$_port_toolchain_root/local.properties"

declare -A _port_toolchain_paths=()
_port_toolchain_loaded=false
declare -a PORT_TOOL_APKTOOL_COMMAND=()
PORT_TOOL_ZIPALIGN=""
PORT_TOOL_AVBTOOL=""
PORT_TOOL_DDK=""
PORT_TOOL_NDK=""

toolchain_fail() {
	printf '! %s\n' "$*" >&2
	return 1
}

toolchain_load_local_properties() {
	local line key value line_number=0

	if [[ "$_port_toolchain_loaded" == true ]]; then
		return 0
	fi
	_port_toolchain_loaded=true
	[[ -e "$_port_toolchain_properties" ]] || return 0
	[[ -f "$_port_toolchain_properties" && ! -L "$_port_toolchain_properties" ]] || {
		toolchain_fail "local.properties 必须是普通文件：$_port_toolchain_properties"
		return 1
	}
	while IFS= read -r line || [[ -n "$line" ]]; do
		line_number=$((line_number + 1))
		line="${line%$'\r'}"
		[[ -z "$line" || "$line" == \#* ]] && continue
		if [[ ! "$line" =~ ^([a-z_]+)=(.+)$ ]]; then
			toolchain_fail "local.properties 第 $line_number 行格式无效，应为 key=/绝对路径"
			return 1
		fi
		key="${BASH_REMATCH[1]}"
		value="${BASH_REMATCH[2]}"
		case "$key" in
			apktool|zipalign|avbtool|ddk|ndk) ;;
			*)
				toolchain_fail "local.properties 第 $line_number 行包含不支持的工具：$key"
				return 1
				;;
		esac
		if [[ "$value" != /* ]]; then
			toolchain_fail "local.properties 第 $line_number 行必须指定绝对路径：$key"
			return 1
		fi
		if [[ -v "_port_toolchain_paths[$key]" ]]; then
			toolchain_fail "local.properties 重复指定工具：$key"
			return 1
		fi
		_port_toolchain_paths["$key"]="$value"
	done < "$_port_toolchain_properties"
}

toolchain_resolve_executable() {
	local tool_name="${1:-}"
	local configured_path=""
	local resolved_path=""

	case "$tool_name" in
		zipalign|avbtool|ddk) ;;
		*) toolchain_fail "不支持解析的特殊工具：$tool_name"; return 1 ;;
	esac
	toolchain_load_local_properties || return 1
	configured_path="${_port_toolchain_paths[$tool_name]:-}"
	if [[ -n "$configured_path" ]]; then
		[[ -f "$configured_path" && ! -L "$configured_path" && -x "$configured_path" ]] || {
			toolchain_fail "local.properties 中的 $tool_name 不可执行：$configured_path"
			return 1
		}
		printf '%s\n' "$configured_path"
		return 0
	fi
	resolved_path="$(command -v -- "$tool_name" 2>/dev/null || true)"
	[[ -n "$resolved_path" ]] || {
		toolchain_fail "缺少特殊工具 $tool_name；请写入 $_port_toolchain_properties"
		return 1
	}
	printf '%s\n' "$resolved_path"
}

toolchain_android_sdk_roots() {
	local variable_name raw_path resolved_path
	declare -A seen_paths=()

	for variable_name in ANDROID_SDK ANDROID_SDK_ROOT ANDROID_HOME; do
		raw_path="${!variable_name:-}"
		[[ -n "$raw_path" && -d "$raw_path" ]] || continue
		resolved_path="$(cd -- "$raw_path" && pwd -P)" || continue
		[[ -v "seen_paths[$resolved_path]" ]] && continue
		seen_paths["$resolved_path"]=1
		printf '%s\n' "$resolved_path"
	done
}

toolchain_resolve_apktool() {
	local configured_path=""
	local resolved_path=""

	toolchain_load_local_properties || return 1
	configured_path="${_port_toolchain_paths[apktool]:-}"
	# shellcheck disable=SC2034 # source 后由调用补丁读取该命令数组。
	PORT_TOOL_APKTOOL_COMMAND=()
	if [[ -n "$configured_path" ]]; then
		[[ -f "$configured_path" && ! -L "$configured_path" && -r "$configured_path" ]] || {
			toolchain_fail "local.properties 中的 apktool 不可读取：$configured_path"
			return 1
		}
		if [[ "$configured_path" == *.jar ]]; then
			command -v java >/dev/null 2>&1 || {
				toolchain_fail "apktool JAR 需要 PATH 中的 java"
				return 1
			}
			PORT_TOOL_APKTOOL_COMMAND=(java -jar "$configured_path")
		else
			[[ -x "$configured_path" ]] || {
				toolchain_fail "local.properties 中的 apktool 不可执行：$configured_path"
				return 1
			}
			PORT_TOOL_APKTOOL_COMMAND=("$configured_path")
		fi
		return 0
	fi
	resolved_path="$(command -v apktool 2>/dev/null || true)"
	[[ -n "$resolved_path" ]] || {
		toolchain_fail "缺少特殊工具 apktool；请写入 $_port_toolchain_properties"
		return 1
	}
	# shellcheck disable=SC2034 # source 后由调用补丁读取该命令数组。
	PORT_TOOL_APKTOOL_COMMAND=("$resolved_path")
}

toolchain_resolve_zipalign() {
	local configured_path=""
	local sdk_root candidate_path resolved_path

	toolchain_load_local_properties || return 1
	configured_path="${_port_toolchain_paths[zipalign]:-}"
	if [[ -n "$configured_path" ]]; then
		[[ -f "$configured_path" && ! -L "$configured_path" && -x "$configured_path" ]] || {
			toolchain_fail "local.properties 中的 zipalign 不可执行：$configured_path"
			return 1
		}
		PORT_TOOL_ZIPALIGN="$configured_path"
		return 0
	fi
	while IFS= read -r sdk_root; do
		candidate_path="$(find "$sdk_root/build-tools" -mindepth 2 -maxdepth 2 \
			-type f -name zipalign -perm -u+x -print 2>/dev/null | LC_ALL=C sort -V | tail -n 1)"
		if [[ -n "$candidate_path" ]]; then
			PORT_TOOL_ZIPALIGN="$candidate_path"
			return 0
		fi
	done < <(toolchain_android_sdk_roots)
	resolved_path="$(command -v zipalign 2>/dev/null || true)"
	[[ -n "$resolved_path" ]] || {
		toolchain_fail "缺少 zipalign；请设置 ANDROID_SDK、ANDROID_SDK_ROOT、ANDROID_HOME 或 local.properties"
		return 1
	}
	# shellcheck disable=SC2034 # source 后由调用补丁读取该路径。
	PORT_TOOL_ZIPALIGN="$resolved_path"
}

toolchain_resolve_avbtool() {
	# shellcheck disable=SC2034 # source 后由调用补丁读取该路径。
	PORT_TOOL_AVBTOOL="$(toolchain_resolve_executable avbtool)" || return 1
}

toolchain_resolve_ddk() {
	# shellcheck disable=SC2034 # source 后由调用补丁读取该路径。
	PORT_TOOL_DDK="$(toolchain_resolve_executable ddk)" || return 1
}

toolchain_resolve_ndk() {
	local configured_path=""
	local variable_name raw_path sdk_root candidate_path

	toolchain_load_local_properties || return 1
	configured_path="${_port_toolchain_paths[ndk]:-}"
	if [[ -n "$configured_path" ]]; then
		[[ -d "$configured_path" && ! -L "$configured_path" ]] || {
			toolchain_fail "local.properties 中的 ndk 不是普通目录：$configured_path"
			return 1
		}
		PORT_TOOL_NDK="$configured_path"
		return 0
	fi
	for variable_name in NDK_HOME ANDROID_NDK_HOME ANDROID_NDK_ROOT; do
		raw_path="${!variable_name:-}"
		[[ -n "$raw_path" && -d "$raw_path" ]] || continue
		PORT_TOOL_NDK="$(cd -- "$raw_path" && pwd -P)"
		return 0
	done
	while IFS= read -r sdk_root; do
		candidate_path="$(find "$sdk_root/ndk" -mindepth 1 -maxdepth 1 \
			-type d -print 2>/dev/null | LC_ALL=C sort -V | tail -n 1)"
		if [[ -n "$candidate_path" ]]; then
			# shellcheck disable=SC2034 # source 后由调用补丁读取该目录。
			PORT_TOOL_NDK="$candidate_path"
			return 0
		fi
	done < <(toolchain_android_sdk_roots)
	toolchain_fail "缺少 NDK；请设置 NDK_HOME、ANDROID_NDK_HOME、ANDROID_NDK_ROOT、ANDROID_SDK、ANDROID_SDK_ROOT、ANDROID_HOME 或 local.properties"
	return 1
}
