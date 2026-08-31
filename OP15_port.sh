#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port="$script_dir/port_main.sh"
oneplus15_config_dir="$script_dir/devices/oneplus15/config"
# 一加 15 流程明确选用的可选 SKU 附加配置；缺失时只警告并继续。
export DEVICE_IDENTITY_PROP=nezha_5.9.9.prop
# 一加 15 组合流程固定覆盖原包机型显示名。
export DEVICE_DISPLAY_NAME='OnePlus 15'
# Android framework 使用的物理 Display ID；调用方可在环境中显式覆盖。
export PORT_TARGET_DISPLAY_ID="${PORT_TARGET_DISPLAY_ID:-4630946903293830803}"
# 开机亮度 Overlay 与旧自动亮度 Overlay 清理由 common/fix_boot_brightness 的
# oneplus15 Profile 承担；该 Profile 不做曲线校准（显示取材在 common/coloros_display）。
export BOOT_BRIGHTNESS_PROFILE=oneplus15
# ColorOS displayconfig 接入锁定 oneplus15 Profile；未注入时模块会按底包识别值自动匹配。
export COLOROS_DISPLAY_PROFILE=oneplus15
export DISPLAY_POLICY_ODM_PROPERTIES_FILE="$oneplus15_config_dir/display_odm.props"
export DISPLAY_POLICY_VENDOR_PROPERTIES_FILE="$oneplus15_config_dir/display_vendor.props"
# OnePlus 15 AD296 原厂 ADFR RUS 输入。features/fix_oplus_ltpo 只消费这个显式
# 配置，不从小米原包、DT 或其他机型猜测 1/55Hz 策略。
export OPLUS_ADFR_RUS_XML_FILE="$oneplus15_config_dir/adfr2minfps.xml"
# OnePlus 15 AD296 Apollo DBV-to-nit database. This project-owned asset is
# decoded and checked; the bottom-package libsdmcore input is identified by
# its Apollo ELF/parser contract so it can vary across OTA revisions.
export OPLUS_APOLLO_PANEL_CONFIG_ASSET="$oneplus15_config_dir/display_apollo_list_AD296_P_3_A0020_dsc_cmd_mode_panel.xml.gz.b64"
export OPLUS_APOLLO_PANEL_CONFIG_RELATIVE_PATH='etc/display_apollo_list_AD296_P_3_A0020_dsc_cmd_mode_panel.xml'
export OPLUS_APOLLO_PANEL_CONFIG_SHA256='0d151bb437896d6bb7eaa2d3f9f6df9339499ab97858bfdb269b80b087717234'
export NFC_PROPERTIES_FILE="$oneplus15_config_dir/nfc.props"
export LINEAR_HAPTIC_PROPERTIES_FILE="$oneplus15_config_dir/linear_haptic.props"
export LINEAR_HAPTIC_MOTOR_TYPE=linear
# Millet 核心桥使用本机 DDK 已有的 Android 16 / 6.12 预编译目录。
export KMI='android16-6.12'
# 一加 15 实机硬件快照。超声波指纹通用模块不从小米原包推断这些参数。
export ULTRASONIC_FP_PROPERTIES_FILE="$oneplus15_config_dir/fingerprint.props"
export OPLUS_DOUBLE_TAP_PROPERTIES_FILE="$oneplus15_config_dir/double_tap_wake.props"
export DEVICE_PARAMS_SPOOF_JSON='{
  "language": "zhCN",
  "basic": {
    "Mishop": {
      "RightValue": "",
      "ShowRedDot": "false",
      "Url": ""
    },
    "BasicInfoToggle": 1,
    "BasicItems": [
      {"Title": "处理器", "Summary": "第五代骁龙®8至尊版移动平台", "Index": 0},
      {"Title": "电池容量", "Summary": "7300mAh(典型)", "Index": 1},
      {"Title": "后置摄像头", "Summary": "50MP+50MP+50MP", "Index": 2},
      {"Title": "屏幕尺寸", "Summary": "6.78″", "Index": 3},
      {"Title": "分辨率", "Summary": "2772 x 1272", "Index": 4},
      {"Title": "安全芯片", "Summary": "NFC 安全芯片 SN220T", "Index": 7}
    ]
  },
  "camera": {
    "status": true,
    "data": {
      "BasicInfoToggle": 1,
      "camera": {
        "front_camera": "32MP",
        "rear_camera": "50MP+50MP+50MP"
      }
    }
  }
}'
export DEVICE_PARAMS_SPOOF_JSON_ENUS='{
  "language": "enUS",
  "basic": {
    "Mishop": {
      "RightValue": "",
      "ShowRedDot": "false",
      "Url": ""
    },
    "BasicInfoToggle": 1,
    "BasicItems": [
      {"Title": "CPU", "Summary": "Snapdragon® 8 Elite Gen 5 Mobile Platform", "Index": 0},
      {"Title": "Battery capacity", "Summary": "7300mAh (typ)", "Index": 1},
      {"Title": "Rear camera", "Summary": "50MP+50MP+50MP", "Index": 2},
      {"Title": "Screen size", "Summary": "6.78″", "Index": 3},
      {"Title": "Resolution", "Summary": "2772 x 1272", "Index": 4},
      {"Title": "Security chip", "Summary": "NFC Security Chip SN220T", "Index": 7}
    ]
  },
  "camera": {
    "status": true,
    "data": {
      "BasicInfoToggle": 1,
      "camera": {
        "front_camera": "32MP",
        "rear_camera": "50MP+50MP+50MP"
      }
    }
  }
}'
settings_apk_session_dir="$(mktemp -d "${TMPDIR:-/tmp}/op15-settings-apk.XXXXXX")"
# shellcheck disable=SC2329 # 由 EXIT trap 间接调用。
cleanup_settings_apk_session() {
	find "$settings_apk_session_dir" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup_settings_apk_session EXIT
export APK_PATCHER_SESSION_DIR="$settings_apk_session_dir"

set +e
bash "$port" common/merge_mi_ext \
	common/fuck_oplus_hybridzram \
	common/disable_mi_vulkan \
	features/fuck_audio_appname \
	features/fix_oplus_lhdc \
	common/disable_odm_imports \
	common/fake_device_params \
	common/fix_pangu \
	common/fix_mi_account \
	common/fix_sn \
	common/enable_hyperos_features \
	common/fix_camera_mr \
	common/fix_face_unlock \
	features/fix_nci_nfc \
	features/oplus_displayfeature_bridge \
	features/fix_oplus_double_tap_wake \
	features/fix_ultrasonic_fingerprint \
	features/oplus_millet_core_bridge \
	common/fix_launcher \
	common/fix_device_identity \
	features/fix_oplus_ltpo \
	common/fix_oplus_avc \
	common/fix_wechat_safe_mode \
	common/fix_settings_haptic \
	common/fix_modem_xts \
	common/fix_mtp \
	common/fix_mi_mtp_kill_self \
	features/fix_oplus_fingerprint_protocol \
	common/coloros_display \
	common/fix_vendor_avc \
	common/fix_boot_brightness \
	common/fix_boot_refresh_rate \
	devices/oneplus15/fix_refresh_rate_switch \
	features/fix_linear_haptic
port_status=$?
set -e

if [[ -f "$settings_apk_session_dir/ready" ]]; then
	set +e
	bash "$script_dir/tools/apk_patcher.sh" finalize "$settings_apk_session_dir"
	finalize_status=$?
	set -e
	if (( finalize_status != 0 && port_status == 0 )); then
		port_status=$finalize_status
	fi
fi

if (( port_status == 0 )); then
	printf '✅ 所有补丁处理完成，Settings 统一回编译已收尾\n'
else
	printf '! FAIL: 组合流程失败，exit=%s\n' "$port_status" >&2
fi
exit "$port_status"
