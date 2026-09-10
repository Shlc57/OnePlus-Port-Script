#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

std_print "修复 HyperOS 小爱同学 DSP 唤醒"
std_print "迁移原包 Qualcomm 声学唤醒模型到底包 odm，并对齐声学属性与 PAL 并发采集配置"
std_print

hook_props_config="$patcher_dir/config/hook.props"
hook_apk_prebuilt="$patcher_dir/prebuilt/XiaoAiRecognitionHook.apk"
# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154 # init_port_env 在执行模块前导出 project_dir。
hook_apk_target_dir="$project_dir/system_ext/app/XiaoAiRecognitionHook"
hook_apk_target="$hook_apk_target_dir/XiaoAiRecognitionHook.apk"

mi_odm_etc_dir="$project_dir/mi_odm/etc"
mi_odm_build_prop="$mi_odm_etc_dir/build.prop"
odm_etc_dir="$project_dir/odm/etc"
odm_build_prop="$odm_etc_dir/build.prop"
vendor_build_prop="$project_dir/vendor/build.prop"
odm_pal_config="$odm_etc_dir/resourcemanager.xml"
odm_contexts="$(get_part_contexts_path odm)"
odm_fsconfig="$(get_part_fsconfig_path odm)"
system_ext_contexts="$(get_part_contexts_path system_ext)"
system_ext_fsconfig="$(get_part_fsconfig_path system_ext)"
odm_property_contexts="$project_dir/odm/etc/selinux/odm_property_contexts"
selinux_bundle_manifest="$patcher_dir/config/selinux_bundle.tsv"
selinux_policy_fragment="$patcher_dir/config/selinux_policy.cil.in"
xiaoai_property_contexts="$patcher_dir/config/xiaoai_property_contexts"

xiaoai_property_keys=(
	ro.vendor.audio.soundtrigger.xiaomievent
	ro.vendor.audio.soundtrigger.permian
	ro.vendor.audio.soundtrigger.wakeupword
	ro.vendor.audio.soundtrigger.is_force_alarm_voiceassistant_deepbuffer
	ro.vendor.audio.soundtrigger.support_record_type
	ro.vendor.audio.voiceassist.support_record_type
	ro.vendor.audio.soundtrigger.sva-7.0
)

parameter_file="${XIAOAI_WAKEUP_PROPERTIES_FILE:-}"
odm_prjname=""
pal_concurrent_capture=false
# hook 默认关闭：其模型注入目标是 SM8750 的 /odm/etc/XiaoAiTongXue.uim，
# SM8845/SM8850 原包 VoiceTrigger 原生直读 /odm/etc/XiaoAiTongXueMi.udm，
# 启用 hook 反而会替换掉正确的模型数据。仅供 SM8750 代组合（一加 13、
# Ace 6）验证后显式开启。
recognition_hook=false
declare -a parameter_prop_overrides=()

# 原包 odm 不存在，或未提供 Qualcomm 声学唤醒模型时，本特性不适用，安全跳过。
if [[ ! -d "$mi_odm_etc_dir" ]]; then
	warn_print "原包未解包 mi_odm/etc，跳过小爱唤醒修复"
	exit 0
fi

declare -a model_source_files=()
while IFS= read -r model_file; do
	model_source_files+=("$model_file")
done < <(find "$mi_odm_etc_dir" -maxdepth 1 -type f \( -name '*.udm' -o -name '*.uim' \) | LC_ALL=C sort)

if (( ${#model_source_files[@]} == 0 )); then
	warn_print "原包 mi_odm/etc 未提供 Qualcomm 声学唤醒模型（*.udm/*.uim），跳过小爱唤醒修复"
	exit 0
fi

xiaoai_model_found=0
for model_file in "${model_source_files[@]}"; do
	model_name="$(basename -- "$model_file")"
	if [[ "${model_name,,}" == xiaoaitongxue* ]]; then
		xiaoai_model_found=1
		break
	fi
done
if (( xiaoai_model_found == 0 )); then
	warn_print "原包声学唤醒模型缺少 XiaoAiTongXue 主模型，VoiceTrigger 无法加载，跳过小爱唤醒修复"
	exit 0
fi

if [[ -n "$parameter_file" ]]; then
	if [[ -L "$parameter_file" ]]; then
		err_print "小爱唤醒参数配置不能是符号链接：$parameter_file"
		exit 1
	elif [[ ! -e "$parameter_file" ]]; then
		err_print "小爱唤醒参数配置不存在：$parameter_file"
		exit 1
	elif [[ ! -f "$parameter_file" ]]; then
		err_print "小爱唤醒参数配置不是普通文件：$parameter_file"
		exit 1
	fi
	validate_prop_file "$parameter_file"

	while IFS= read -r parameter_line || [[ -n "$parameter_line" ]]; do
		parameter_line="${parameter_line%$'\r'}"
		parameter_line="${parameter_line#"${parameter_line%%[![:space:]]*}"}"
		[[ -z "$parameter_line" || "$parameter_line" == \#* ]] && continue
		parameter_name="${parameter_line%%=*}"
		parameter_name="${parameter_name%"${parameter_name##*[![:space:]]}"}"
		parameter_value="${parameter_line#*=}"
		parameter_value="${parameter_value%"${parameter_value##*[![:space:]]}"}"
		case "$parameter_name" in
			pal_concurrent_capture|recognition_hook)
				if [[ "$parameter_value" != true && "$parameter_value" != false ]]; then
					err_print "小爱唤醒参数 $parameter_name 只接受 true/false：$parameter_value"
					exit 1
				fi
				printf -v "$parameter_name" '%s' "$parameter_value"
				;;
			odm.prjname)
				if [[ ! "$parameter_value" =~ ^[0-9]+$ ]]; then
					err_print "小爱唤醒参数 odm.prjname 必须是纯数字（ro.boot.prjname）：$parameter_value"
					exit 1
				fi
				odm_prjname="$parameter_value"
				;;
			persist.sys.xiaoai.*|\
			ro.vendor.audio.soundtrigger.xiaomievent|\
			ro.vendor.audio.soundtrigger.permian|\
			ro.vendor.audio.soundtrigger.wakeupword|\
			ro.vendor.audio.soundtrigger.is_force_alarm_voiceassistant_deepbuffer|\
			ro.vendor.audio.soundtrigger.support_record_type|\
			ro.vendor.audio.voiceassist.support_record_type|\
			ro.vendor.audio.soundtrigger.sva-7.0)
				parameter_prop_overrides+=("$parameter_name=$parameter_value")
				;;
			*)
				err_print "小爱唤醒参数配置包含未知属性：$parameter_name"
				exit 1
				;;
		esac
	done < "$parameter_file"
fi

check_part_exists odm
check_part_exists vendor
for required_file in \
	"$odm_build_prop" \
	"$vendor_build_prop" \
	"$odm_contexts" \
	"$odm_fsconfig" \
	"$selinux_bundle_manifest" \
	"$selinux_policy_fragment" \
	"$xiaoai_property_contexts"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "小爱唤醒输入不能是符号链接：$required_file"
		exit 1
	fi
done

load_selinux_bundle_manifest "$selinux_bundle_manifest" "$patcher_dir"
expected_bundle_requirements=(
	product/app/VoiceTrigger/VoiceTrigger.apk
	product/priv-app/VoiceAssistAndroidT/VoiceAssistAndroidT.apk
)
if (( ${#SELINUX_BUNDLE_REQUIREMENTS[@]} != 2 ||
	${#SELINUX_BUNDLE_POLICY_FRAGMENTS[@]} != 1 ||
	${#SELINUX_BUNDLE_CONTEXT_FRAGMENTS[@]} != 2 )); then
	err_print "小爱唤醒 SELinux bundle 的 requirement/policy/contexts 结构不完整"
	exit 1
fi
for requirement_index in "${!expected_bundle_requirements[@]}"; do
	if [[ "${SELINUX_BUNDLE_REQUIREMENTS[$requirement_index]}" != \
		"${expected_bundle_requirements[$requirement_index]}" ]]; then
		err_print "小爱唤醒 SELinux bundle requirement 与应用读取契约不一致"
		exit 1
	fi
done
if [[ "${SELINUX_BUNDLE_POLICY_FRAGMENTS[0]}" != "$(realpath -e -- "$selinux_policy_fragment")" ||
	"${SELINUX_BUNDLE_CONTEXT_TARGETS[0]}" != vendor_property_contexts ||
	"${SELINUX_BUNDLE_CONTEXT_TARGETS[1]}" != precompiled_property_contexts ||
	"${SELINUX_BUNDLE_CONTEXT_FRAGMENTS[0]}" != "$(realpath -e -- "$xiaoai_property_contexts")" ||
	"${SELINUX_BUNDLE_CONTEXT_FRAGMENTS[1]}" != "$(realpath -e -- "$xiaoai_property_contexts")" ]]; then
	err_print "小爱唤醒 SELinux bundle 未唯一引用模块自有策略与 property contexts"
	exit 1
fi
mapfile -t policy_statements < <(grep -Ev '^[[:space:]]*($|;)' "$selinux_policy_fragment")
# shellcheck disable=SC2016 # 校验模板必须保留供 fix_vendor_avc 替换的字面占位符。
if (( ${#policy_statements[@]} != 1 )) ||
	[[ "${policy_statements[0]}" != '(allow platform_app_${API_VERSION} vendor_audio_prop (file (read getattr map open)))' ]]; then
	err_print "小爱唤醒 SELinux policy 必须只允许 platform_app 读取 vendor_audio_prop"
	exit 1
fi
mapfile -t property_context_lines < <(grep -Ev '^[[:space:]]*($|#)' "$xiaoai_property_contexts")
if (( ${#property_context_lines[@]} != ${#xiaoai_property_keys[@]} )); then
	err_print "小爱唤醒 property contexts 必须精确包含七个属性键"
	exit 1
fi
for property_index in "${!xiaoai_property_keys[@]}"; do
	if [[ "${property_context_lines[$property_index]}" != \
		"${xiaoai_property_keys[$property_index]} u:object_r:vendor_audio_prop:s0 exact" ]]; then
		err_print "小爱唤醒 property contexts 内容或顺序不符合七属性契约"
		exit 1
	fi
done
# SELinux bundle 由后续 common/fix_vendor_avc 统一按 APK requirement 激活；
# DSP 模型与属性迁移不能因可选应用目标缺失而失败。

prepare_odm_property_contexts=false
if [[ -e "$odm_property_contexts" || -L "$odm_property_contexts" ]]; then
	if [[ ! -f "$odm_property_contexts" || -L "$odm_property_contexts" ]]; then
		err_print "ODM property contexts 不是安全普通文件：$odm_property_contexts"
		exit 1
	fi
	prepare_odm_property_contexts=true
fi

if [[ "$pal_concurrent_capture" == true ]] && [[ ! -s "$odm_pal_config" ]]; then
	err_print "底包缺少 PAL 声学配置：odm/etc/resourcemanager.xml"
	exit 1
fi

if [[ -L "$odm_etc_dir" || ! -d "$odm_etc_dir" ]]; then
	err_print "小爱唤醒 ODM etc 目录不存在或不安全：$odm_etc_dir"
	exit 1
fi

rc_target_dir="$odm_etc_dir/init"
rc_target="$rc_target_dir/xiaoai_wakeup_props.rc"
declare -a odm_new_target_dirs=("$rc_target_dir")
declare -a odm_new_target_files=("$rc_target")
if [[ -n "$odm_prjname" ]]; then
	prjname_prop_dir="$odm_etc_dir/$odm_prjname"
	prjname_prop_file="$prjname_prop_dir/build.gsi.prop"
	odm_new_target_dirs+=("$prjname_prop_dir")
	odm_new_target_files+=("$prjname_prop_file")
fi
for target_dir in "${odm_new_target_dirs[@]}"; do
	if [[ -L "$target_dir" || ( -e "$target_dir" && ! -d "$target_dir" ) ]]; then
		err_print "小爱唤醒目标父目录类型不安全：$target_dir"
		exit 1
	fi
	resolved_target_dir="$(realpath -m -- "$target_dir")"
	case "$resolved_target_dir" in
		"$project_dir/odm"/*) ;;
		*)
			err_print "小爱唤醒目标父目录越出 ODM：$target_dir"
			exit 1
			;;
	esac
done
for target_file in "${odm_new_target_files[@]}"; do
	if [[ -L "$target_file" || -d "$target_file" ]]; then
		err_print "小爱唤醒目标文件类型不安全：$target_file"
		exit 1
	fi
done

if [[ "$recognition_hook" == true ]]; then
	check_part_exists system_ext
	for hook_input in \
		"$hook_props_config" \
		"$hook_apk_prebuilt" \
		"$system_ext_contexts" \
		"$system_ext_fsconfig"; do
		check_file_exists "$hook_input"
		if [[ -L "$hook_input" ]]; then
			err_print "小爱唤醒 hook 输入不能是符号链接：$hook_input"
			exit 1
		fi
	done
fi

temporary_files=()
cleanup() {
	local temporary_file
	for temporary_file in "${temporary_files[@]}"; do
		rm -f -- "$temporary_file"
	done
}
trap cleanup EXIT

printf -v xiaoai_property_key_list '%s\n' "${xiaoai_property_keys[@]}"
temporary_odm_property_contexts=""
if [[ "$prepare_odm_property_contexts" == true ]]; then
	temporary_odm_property_contexts="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_odm_property_contexts.XXXXXX')")"
	temporary_files+=("$temporary_odm_property_contexts")
	# shellcheck disable=SC2016 # 属性键集合经 PORT_XIAOAI_PROPERTY_KEYS 注入 awk。
	env PORT_XIAOAI_PROPERTY_KEYS="$xiaoai_property_key_list" awk '
		BEGIN {
			key_count = split(ENVIRON["PORT_XIAOAI_PROPERTY_KEYS"], keys, "\n")
			for (i = 1; i <= key_count; i++) wanted[keys[i]] = 1
		}
		{
			if (NF == 3 && ($1 in wanted) &&
				$2 == "u:object_r:vendor_default_prop:s0" && $3 == "exact") next
			print
		}
	' "$odm_property_contexts" >"$temporary_odm_property_contexts"
	for property_key in "${xiaoai_property_keys[@]}"; do
		if awk -v expected_key="$property_key" '
			NF == 3 && $1 == expected_key &&
				$2 == "u:object_r:vendor_default_prop:s0" && $3 == "exact" { found = 1 }
			END { exit found ? 0 : 1 }
		' "$temporary_odm_property_contexts"; then
			err_print "ODM property contexts 历史标签清理失败：$property_key"
			exit 1
		fi
	done
fi

generated_prop="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_prop.XXXXXX')")"
temporary_files+=("$generated_prop")
: >"$generated_prop"

# 原包 odm 声学属性是小爱唤醒的权威来源；只迁移 bundle 精确标注的七个键。
# 缺失时只跳过属性子步骤，模型迁移继续。
prop_source_ready=1
if [[ -L "$mi_odm_build_prop" ]]; then
	err_print "不支持从符号链接读取原包声学属性：$mi_odm_build_prop"
	exit 1
elif [[ ! -e "$mi_odm_build_prop" ]]; then
	warn_print "原包 mi_odm/etc/build.prop 不存在，跳过声学属性迁移"
	prop_source_ready=0
elif [[ ! -f "$mi_odm_build_prop" ]]; then
	err_print "原包声学属性来源不是普通文件：$mi_odm_build_prop"
	exit 1
fi
if (( prop_source_ready == 1 )); then
	# shellcheck disable=SC2016 # 属性键集合经 PORT_XIAOAI_PROPERTY_KEYS 注入 awk。
	env PORT_XIAOAI_PROPERTY_KEYS="$xiaoai_property_key_list" awk '
		BEGIN {
			key_count = split(ENVIRON["PORT_XIAOAI_PROPERTY_KEYS"], keys, "\n")
			for (i = 1; i <= key_count; i++) wanted[keys[i]] = 1
		}
		{
			line = $0
			sub(/\r$/, "", line)
			candidate = line
			sub(/^[[:space:]]*/, "", candidate)
			if (candidate == "" || substr(candidate, 1, 1) == "#") next
			separator = index(candidate, "=")
			if (separator < 2) next
			key = substr(candidate, 1, separator - 1)
			gsub(/[[:space:]]/, "", key)
			if (key in wanted) print line
		}
	' "$mi_odm_build_prop" >>"$generated_prop"
fi

if [[ "$recognition_hook" == true ]]; then
	validate_prop_file "$hook_props_config"
	cat "$hook_props_config" >>"$generated_prop"
fi

if (( ${#parameter_prop_overrides[@]} > 0 )); then
	override_prop="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_override.XXXXXX')")"
	temporary_files+=("$override_prop")
	printf '%s\n' "${parameter_prop_overrides[@]}" >"$override_prop"
	merge_prop_file "$override_prop" "$generated_prop"
fi

# PAL concurrent_capture 仅由机型组合显式开启：避免把其他设备的调优值
# 隐式应用到未验证平台。开启后可避免 DSP 会话与普通录音并发时反复重启。
pal_updated=0
if [[ "$pal_concurrent_capture" == true ]]; then
	concurrent_occurrences="$(grep -c '<param concurrent_capture="' "$odm_pal_config" || true)"
	if [[ "$concurrent_occurrences" != "1" ]]; then
		warn_print "底包 PAL concurrent_capture 参数形态不受支持（出现 $concurrent_occurrences 次），跳过 PAL 调整"
	else
		concurrent_value="$(sed -n 's/.*<param concurrent_capture="\([^"]*\)".*/\1/p' "$odm_pal_config")"
		if [[ "$concurrent_value" == "true" ]]; then
			std_print "底包 PAL concurrent_capture 已经为 true"
		elif [[ "$concurrent_value" != "false" ]]; then
			warn_print "底包 PAL concurrent_capture 取值不受支持：$concurrent_value，跳过 PAL 调整"
		else
			generated_pal="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_pal.XXXXXX')")"
			temporary_files+=("$generated_pal")
			sed 's|<param concurrent_capture="false" />|<param concurrent_capture="true" />|' \
				"$odm_pal_config" >"$generated_pal"
			if [[ "$(grep -c '<param concurrent_capture="' "$generated_pal")" != "1" ]] || \
				! grep -Fq '<param concurrent_capture="true" />' "$generated_pal"; then
				err_print "PAL concurrent_capture 替换结果校验失败"
				exit 1
			fi
			pal_updated=1
		fi
	fi
fi

generated_odm_contexts="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_odm_contexts.XXXXXX')")"
generated_odm_fsconfig="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_odm_fsconfig.XXXXXX')")"
temporary_files+=("$generated_odm_contexts" "$generated_odm_fsconfig")
: >"$generated_odm_contexts"
: >"$generated_odm_fsconfig"
for model_file in "${model_source_files[@]}"; do
	model_name="$(basename -- "$model_file")"
	model_name_escaped="${model_name//./\\.}"
	printf '/odm/etc/%s u:object_r:vendor_configs_file:s0\n' "$model_name_escaped" >>"$generated_odm_contexts"
	printf 'odm/etc/%s 0 0 0644\n' "$model_name" >>"$generated_odm_fsconfig"
done

has_generated_props=0
generated_rc=""
temporary_odm_build_prop=""
temporary_vendor_build_prop=""
if grep -qE '^[[:space:]]*[^#[:space:]]' "$generated_prop"; then
	has_generated_props=1
	validate_prop_file "$generated_prop"

	# 先生成所有属性载体，完成派生输出校验前不写工作树。
	temporary_odm_build_prop="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_odm_prop.XXXXXX')")"
	temporary_vendor_build_prop="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_vendor_prop.XXXXXX')")"
	generated_rc="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_rc.XXXXXX')")"
	temporary_files+=("$temporary_odm_build_prop" "$temporary_vendor_build_prop" "$generated_rc")
	# shellcheck disable=SC2016 # 变量经 PORT_PROP_SOURCE/PORT_PROP_MARKER 注入。
	if ! env PORT_PROP_SOURCE="$generated_prop" \
		PORT_PROP_MARKER='# fix_xiaoai_dsp_wakeup 声学属性（追加区，勿上移）' \
		awk '
			function trim_key(line) {
				sep = index(line, "=")
				if (sep < 2) return ""
				key = substr(line, 1, sep - 1)
				gsub(/[[:space:]]/, "", key)
				return key
			}
			BEGIN {
				source_file = ENVIRON["PORT_PROP_SOURCE"]
				marker = ENVIRON["PORT_PROP_MARKER"]
				while ((getline source_line < source_file) > 0) {
					sub(/\r$/, "", source_line)
					source_candidate = source_line
					sub(/^[[:space:]]*/, "", source_candidate)
					if (source_candidate == "" || substr(source_candidate, 1, 1) == "#") continue
					source_key = trim_key(source_candidate)
					if (source_key != "" && !(source_key in seen_keys)) {
						seen_keys[source_key] = 1
						prop_lines[++prop_count] = source_line
					}
				}
				close(source_file)
			}
			{
				if (index($0, marker) == 1) next
				line = $0
				sub(/\r$/, "", line)
				candidate = line
				sub(/^[[:space:]]*/, "", candidate)
				if (candidate == "" || substr(candidate, 1, 1) == "#") {
					print line
					next
				}
				key = trim_key(candidate)
				if (key != "" && (key in seen_keys)) next
				print line
			}
			END {
				print marker
				for (i = 1; i <= prop_count; i++) print prop_lines[i]
			}
		' "$odm_build_prop" >"$temporary_odm_build_prop"; then
		err_print "odm/etc/build.prop 声学属性重定位失败"
		exit 1
	fi
	cp -p -- "$vendor_build_prop" "$temporary_vendor_build_prop"
	merge_prop_file "$generated_prop" "$temporary_vendor_build_prop"

	{
		printf '%s\n' '# 小爱唤醒声学属性（init rc 载体）' 'on boot'
		env PORT_PROP_SOURCE="$generated_prop" awk '
			BEGIN {
				source_file = ENVIRON["PORT_PROP_SOURCE"]
				while ((getline line < source_file) > 0) {
					sub(/\r$/, "", line)
					if (line !~ /^[A-Za-z0-9_.-]+=[^=]/) continue
					sep = index(line, "=")
					print "    setprop " substr(line, 1, sep - 1) " " substr(line, sep + 1)
				}
				close(source_file)
			}
		'
	} >"$generated_rc"
	if ! grep -qE '^[[:space:]]+setprop[[:space:]]+' "$generated_rc"; then
		err_print "小爱唤醒 init rc 未生成有效 setprop"
		exit 1
	fi
	printf '%s\n' \
		'/odm/etc/init/xiaoai_wakeup_props\.rc u:object_r:vendor_configs_file:s0' \
		>>"$generated_odm_contexts"
	printf '%s\n' \
		'odm/etc/init 0 0 0755' \
		'odm/etc/init/xiaoai_wakeup_props.rc 0 0 0644' \
		>>"$generated_odm_fsconfig"

	if [[ -n "$odm_prjname" ]]; then
		printf '/odm/etc/%s u:object_r:vendor_configs_file:s0\n' "$odm_prjname" >>"$generated_odm_contexts"
		printf '/odm/etc/%s/build\\.gsi\\.prop u:object_r:vendor_configs_file:s0\n' "$odm_prjname" >>"$generated_odm_contexts"
		printf 'odm/etc/%s 0 0 0755\n' "$odm_prjname" >>"$generated_odm_fsconfig"
		printf 'odm/etc/%s/build.gsi.prop 0 0 0644\n' "$odm_prjname" >>"$generated_odm_fsconfig"
	fi
fi

generated_system_ext_contexts=""
generated_system_ext_fsconfig=""
if [[ "$recognition_hook" == true ]]; then
	generated_system_ext_contexts="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_sext_contexts.XXXXXX')")"
	generated_system_ext_fsconfig="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_sext_fsconfig.XXXXXX')")"
	temporary_files+=("$generated_system_ext_contexts" "$generated_system_ext_fsconfig")
	cat >"$generated_system_ext_contexts" <<'EOF'
/system_ext/app/XiaoAiRecognitionHook u:object_r:system_file:s0
/system_ext/app/XiaoAiRecognitionHook/XiaoAiRecognitionHook\.apk u:object_r:system_file:s0
EOF
	cat >"$generated_system_ext_fsconfig" <<'EOF'
system_ext/app/XiaoAiRecognitionHook 0 0 0755
system_ext/app/XiaoAiRecognitionHook/XiaoAiRecognitionHook.apk 0 0 0644
EOF
fi

temporary_odm_contexts="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_odm_ctx.XXXXXX')")"
temporary_odm_fsconfig="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_odm_fsc.XXXXXX')")"
temporary_files+=("$temporary_odm_contexts" "$temporary_odm_fsconfig")
cp -p -- "$odm_contexts" "$temporary_odm_contexts"
cp -p -- "$odm_fsconfig" "$temporary_odm_fsconfig"
merge_contexts_file "$generated_odm_contexts" "$temporary_odm_contexts"
merge_fsconfig_file "$generated_odm_fsconfig" "$temporary_odm_fsconfig"

if [[ "$recognition_hook" == true ]]; then
	temporary_system_ext_contexts="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_sext_ctx.XXXXXX')")"
	temporary_system_ext_fsconfig="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_sext_fsc.XXXXXX')")"
	temporary_files+=("$temporary_system_ext_contexts" "$temporary_system_ext_fsconfig")
	cp -p -- "$system_ext_contexts" "$temporary_system_ext_contexts"
	cp -p -- "$system_ext_fsconfig" "$temporary_system_ext_fsconfig"
	merge_contexts_file "$generated_system_ext_contexts" "$temporary_system_ext_contexts"
	merge_fsconfig_file "$generated_system_ext_fsconfig" "$temporary_system_ext_fsconfig"
fi

# 所有派生输出均已生成并校验，从这里开始才修改工作树。
for model_file in "${model_source_files[@]}"; do
	model_name="$(basename -- "$model_file")"
	replace_file_if_different "$model_file" "$odm_etc_dir/$model_name"
	chmod 0644 -- "$odm_etc_dir/$model_name"
	std_print "✅ 已迁移声学唤醒模型：odm/etc/$model_name"
done

if (( pal_updated == 1 )); then
	_install_generated_file "$generated_pal" "$odm_pal_config"
	std_print "✅ 已开启底包 PAL concurrent_capture（DSP 与普通录音并发）"
fi

if [[ "$recognition_hook" == true ]]; then
	mkdir -p -- "$hook_apk_target_dir"
	replace_file_if_different "$hook_apk_prebuilt" "$hook_apk_target"
	chmod 0644 -- "$hook_apk_target"
	std_print "✅ 已预装 LSPosed 识别修复 hook：system_ext/app/XiaoAiRecognitionHook"
	std_print "ℹ️ hook 需在设备 LSPosed 中启用并勾选 com.miui.voicetrigger 作用域"
fi

if (( has_generated_props == 1 )); then
	_install_generated_file "$temporary_odm_build_prop" "$odm_build_prop"
	_install_generated_file "$temporary_vendor_build_prop" "$vendor_build_prop"
	std_print "✅ 声学属性已写入 odm/etc/build.prop 与 vendor/build.prop"

	mkdir -p -- "$rc_target_dir"
	replace_file_if_different "$generated_rc" "$rc_target"
	chmod 0644 -- "$rc_target"
	std_print "✅ 声学属性已写入 init rc 载体：odm/etc/init/xiaoai_wakeup_props.rc"

	if [[ -n "$odm_prjname" ]]; then
		mkdir -p -- "$prjname_prop_dir"
		replace_file_if_different "$generated_prop" "$prjname_prop_file"
		chmod 0644 -- "$prjname_prop_file"
		std_print "✅ 声学属性已写入 import 链目标：odm/etc/$odm_prjname/build.gsi.prop"
	fi
fi

_install_generated_file "$temporary_odm_contexts" "$odm_contexts"
_install_generated_file "$temporary_odm_fsconfig" "$odm_fsconfig"
if [[ "$prepare_odm_property_contexts" == true ]]; then
	_install_generated_file "$temporary_odm_property_contexts" "$odm_property_contexts"
	std_print "✅ 已清理 ODM 中七个小爱属性的历史 vendor_default_prop exact 标签"
fi
if [[ "$recognition_hook" == true ]]; then
	_install_generated_file "$temporary_system_ext_contexts" "$system_ext_contexts"
	_install_generated_file "$temporary_system_ext_fsconfig" "$system_ext_fsconfig"
fi

std_print "处理完成"
