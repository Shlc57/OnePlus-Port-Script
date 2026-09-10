#!/bin/bash
set -euo pipefail

patcher_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
init_port_env "${1:-}"

xiaoai_voicetrigger_patch="${XIAOAI_VOICETRIGGER_PATCH:-false}"
if [[ "$xiaoai_voicetrigger_patch" != true && "$xiaoai_voicetrigger_patch" != false ]]; then
	err_print "XIAOAI_VOICETRIGGER_PATCH 只接受 true/false：$xiaoai_voicetrigger_patch"
	exit 1
elif [[ "$xiaoai_voicetrigger_patch" == false ]]; then
	skip_print "未启用小爱唤醒 APK 补丁（XIAOAI_VOICETRIGGER_PATCH=false）"
	exit 0
fi

voiceassist_device_code="${XIAOAI_VOICEASSIST_DEVICE_CODE:-}"
if [[ ! "$voiceassist_device_code" =~ ^[a-z0-9][a-z0-9._-]*$ ]]; then
	err_print "XIAOAI_VOICEASSIST_DEVICE_CODE 必须是安全的 Android device token：$voiceassist_device_code"
	exit 1
fi

std_print "修复小爱 VoiceAssist 设备准入并静态植入 VoiceTrigger 唤醒修复"
std_print

# project_dir 由 tools.sh 的 init_port_env 设置。
# shellcheck disable=SC2154
voiceassist_apk="$project_dir/product/priv-app/VoiceAssistAndroidT/VoiceAssistAndroidT.apk"
voice_trigger_apk="$project_dir/product/app/VoiceTrigger/VoiceTrigger.apk"

check_part_exists product
check_file_exists "$patcher_dir/patch_voiceassist_config.sh"
check_file_exists "$patcher_dir/config/PortWakeupHooks.smali"
check_file_exists "$patcher_dir/patch_voicetrigger.sh"

# 两个 APK 都是替换既有文件的独立子步骤；任一目标缺失只警告并跳过该子步骤。
if [[ ! -e "$voiceassist_apk" ]]; then
	warn_print "原包未提供 VoiceAssistAndroidT.apk，跳过设备准入修复：${voiceassist_apk#"$project_dir"/}"
elif [[ -L "$voiceassist_apk" ]]; then
	err_print "VoiceAssistAndroidT.apk 不能是符号链接：$voiceassist_apk"
	exit 1
elif [[ ! -f "$voiceassist_apk" ]]; then
	err_print "VoiceAssistAndroidT.apk 不是普通文件：$voiceassist_apk"
	exit 1
else
	bash "$patcher_dir/patch_voiceassist_config.sh" "$voiceassist_apk" "$voiceassist_device_code"
	std_print "VoiceAssistAndroidT.apk 已添加设备准入：$voiceassist_device_code"
fi

if [[ ! -e "$voice_trigger_apk" ]]; then
	warn_print "原包未提供 VoiceTrigger.apk，跳过小爱唤醒静态植入：${voice_trigger_apk#"$project_dir"/}"
elif [[ -L "$voice_trigger_apk" ]]; then
	err_print "VoiceTrigger.apk 不能是符号链接：$voice_trigger_apk"
	exit 1
elif [[ ! -f "$voice_trigger_apk" ]]; then
	err_print "VoiceTrigger.apk 不是普通文件：$voice_trigger_apk"
	exit 1
else
	bash "$patcher_dir/patch_voicetrigger.sh" "$voice_trigger_apk"
	std_print "VoiceTrigger.apk 已静态植入小爱唤醒修复"
fi

std_print "仅确认两个 APK 的原 Signing Block 字节保留；未确认内容签名摘要有效"
std_print "处理完成"
