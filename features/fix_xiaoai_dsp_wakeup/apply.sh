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
odm_pal_config="$odm_etc_dir/resourcemanager.xml"
odm_contexts="$(get_part_contexts_path odm)"
odm_fsconfig="$(get_part_fsconfig_path odm)"
system_ext_contexts="$(get_part_contexts_path system_ext)"
system_ext_fsconfig="$(get_part_fsconfig_path system_ext)"

parameter_file="${XIAOAI_WAKEUP_PROPERTIES_FILE:-}"
pal_concurrent_capture=true
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
			persist.sys.xiaoai.*|ro.vendor.audio.soundtrigger.*)
				parameter_prop_overrides+=("$parameter_name=$parameter_value")
				;;
			*)
				err_print "小爱唤醒参数配置包含未知属性：$parameter_name"
				exit 1
				;;
		esac
	done < "$parameter_file"
fi

if [[ "$pal_concurrent_capture" == true ]] && [[ ! -s "$odm_pal_config" ]]; then
	err_print "底包缺少 PAL 声学配置：odm/etc/resourcemanager.xml"
	exit 1
fi

check_part_exists odm
check_part_exists system_ext
for required_file in \
	"$hook_props_config" \
	"$odm_build_prop" \
	"$odm_contexts" \
	"$odm_fsconfig" \
	"$system_ext_contexts" \
	"$system_ext_fsconfig"; do
	check_file_exists "$required_file"
	if [[ -L "$required_file" ]]; then
		err_print "小爱唤醒输入不能是符号链接：$required_file"
		exit 1
	fi
done

if [[ "$recognition_hook" == true ]]; then
	check_file_exists "$hook_apk_prebuilt"
	if [[ -L "$hook_apk_prebuilt" ]]; then
		err_print "小爱唤醒 hook 预编译 APK 不能是符号链接：$hook_apk_prebuilt"
		exit 1
	fi
fi

temporary_files=()
cleanup() {
	local temporary_file
	for temporary_file in "${temporary_files[@]}"; do
		rm -f -- "$temporary_file"
	done
}
trap cleanup EXIT

generated_prop="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_prop.XXXXXX')")"
temporary_files+=("$generated_prop")
: >"$generated_prop"

# 原包 odm 声学属性是小爱唤醒的权威来源（wakeupword、permian、sva 版本等），
# 原样迁移到底包 odm build.prop；缺失时只跳过属性子步骤，模型迁移继续。
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
	# 前缀正则通过环境变量传入 awk，单引号脚本中不做 Shell 展开。
	# shellcheck disable=SC2016 # 属性名前缀经 PORT_PROP_PREFIX 注入。
	env PORT_PROP_PREFIX='ro\.vendor\.audio\.(soundtrigger|voiceassist)\.' \
		awk '
			{
				line = $0
				sub(/\r$/, "", line)
				candidate = line
				sub(/^[[:space:]]*/, "", candidate)
				if (candidate == "" || substr(candidate, 1, 1) == "#") {
					next
				}
				if (candidate ~ ENVIRON["PORT_PROP_PREFIX"]) {
					print line
				}
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

# PAL concurrent_capture 默认改为 true：避免 DSP 唤醒会话与普通录音并发时
# VoiceTrigger 反复重启并拖垮音频 HAL。该行为经 OnePlus 13 (SM8750) 验证，
# 其他平台需真机复验，可通过 pal_concurrent_capture=false 关闭。
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
temporary_system_ext_contexts="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_sext_ctx.XXXXXX')")"
temporary_system_ext_fsconfig="$(mktemp "$(get_config_path '.fix_xiaoai_dsp_wakeup_sext_fsc.XXXXXX')")"
temporary_files+=(
	"$temporary_odm_contexts"
	"$temporary_odm_fsconfig"
	"$temporary_system_ext_contexts"
	"$temporary_system_ext_fsconfig"
)
cp -p -- "$odm_contexts" "$temporary_odm_contexts"
cp -p -- "$odm_fsconfig" "$temporary_odm_fsconfig"
cp -p -- "$system_ext_contexts" "$temporary_system_ext_contexts"
cp -p -- "$system_ext_fsconfig" "$temporary_system_ext_fsconfig"
merge_contexts_file "$generated_odm_contexts" "$temporary_odm_contexts"
merge_fsconfig_file "$generated_odm_fsconfig" "$temporary_odm_fsconfig"
if [[ "$recognition_hook" == true ]]; then
	merge_contexts_file "$generated_system_ext_contexts" "$temporary_system_ext_contexts"
	merge_fsconfig_file "$generated_system_ext_fsconfig" "$temporary_system_ext_fsconfig"
fi

# 全部输入与生成 metadata 校验完毕，从这一步开始才修改工作树。
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

if grep -qE '^[[:space:]]*[^#[:space:]]' "$generated_prop"; then
	merge_prop_file "$generated_prop" "$odm_build_prop"
	std_print "✅ 已合并原包声学属性到 odm/etc/build.prop"
fi

_install_generated_file "$temporary_odm_contexts" "$odm_contexts"
_install_generated_file "$temporary_odm_fsconfig" "$odm_fsconfig"
if [[ "$recognition_hook" == true ]]; then
	_install_generated_file "$temporary_system_ext_contexts" "$system_ext_contexts"
	_install_generated_file "$temporary_system_ext_fsconfig" "$system_ext_fsconfig"
fi

std_print "处理完成"
