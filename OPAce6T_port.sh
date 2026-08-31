#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port="$script_dir/port_main.sh"
ace6t_config_dir="$script_dir/devices/oneplus_ace6t/config"
# 一加 Ace 6T 流程明确选用的可选 SKU 附加配置；缺失时只警告并继续。
# 参考流程在澎湃 OS 4 原包上未启用该项，需要时取消注释并确认原包内存在同名文件。
# export DEVICE_IDENTITY_PROP=nezha_5.9.9.prop
# 一加 Ace 6T 组合流程固定覆盖原包机型显示名。
export DEVICE_DISPLAY_NAME='OnePlus Ace 6T'
# 物理 Display ID（common/fix_boot_brightness 的 ace6t Profile 消费，Ace 6T 实测 dumpsys uniqueId）。
export PORT_TARGET_DISPLAY_ID="4630946700822127507"
# 底包显示 Target（Ace 6T = canoe）：fix_boot_refresh_rate 只收集该 Target 的
# PanelResolution，避免混入底包中其他平台的面板分辨率。
export PORT_DISPLAY_TARGET=canoe
# 自动亮度接入 OP15 同款 ColorOS displayconfig 方案：common/coloros_display 按
# Ace 6T Profile 用 my_product 的 P_7 官方表生成原生 autoBrightness 配置。
export COLOROS_DISPLAY_PROFILE=ace6t
# 开机默认亮度由 common/fix_boot_brightness 的 Ace 6T Profile 安装；Overlay 与校验
# 文件都在模块 profiles/ace6t/ 内，作为机型专属预编译产物提供。
export BOOT_BRIGHTNESS_PROFILE=ace6t
export DISPLAY_POLICY_ODM_PROPERTIES_FILE="$ace6t_config_dir/display_odm.props"
export DISPLAY_POLICY_VENDOR_PROPERTIES_FILE="$ace6t_config_dir/display_vendor.props"
export NFC_PROPERTIES_FILE="$ace6t_config_dir/nfc.props"
export LINEAR_HAPTIC_PROPERTIES_FILE="$ace6t_config_dir/linear_haptic.props"
export LINEAR_HAPTIC_MOTOR_TYPE=linear
# Ace 6T 底包 rc 走 mtp.gs0 纯触发器，与模块内置的一加 15 rc（use_ffs_mtp 形态）不同，
# 由 fix_mtp 自适应校验并以这份真底包 rc 替换被原包覆盖的目标。
export FIX_MTP_SOURCE_RC="$ace6t_config_dir/init.usb.configfs.rc"
# Millet 核心桥按 KMI 选择仓库预编译 KO；Ace 6T 实机内核与一加 15 相同（android16-6.12）。
export KMI='android16-6.12'
# Ace 6T 实机超声波指纹硬件快照。通用模块不从小米原包推断这些参数；
# 传感器中心等坐标属换算估算值，刷机后如对不上可直接修改 fingerprint.props 重跑。
export ULTRASONIC_FP_PROPERTIES_FILE="$ace6t_config_dir/fingerprint.props"
# Ace 6T Oplus HBP 双击亮屏参数；初始值沿用一加 15 同平台触控栈，实机需校准。
export OPLUS_DOUBLE_TAP_PROPERTIES_FILE="$ace6t_config_dir/double_tap_wake.props"

# 一加 Ace 6T 目标设备参数展示（Settings 设备参数缓存）。
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
      {"Title": "处理器", "Summary": "第五代骁龙®8移动平台", "Index": 0},
      {"Title": "电池容量", "Summary": "8300mAh(典型)", "Index": 1},
      {"Title": "后置摄像头", "Summary": "50MP+8MP", "Index": 2},
      {"Title": "屏幕尺寸", "Summary": "6.83″", "Index": 3},
      {"Title": "分辨率", "Summary": "2800 x 1272", "Index": 4}
    ]
  },
  "camera": {
    "status": true,
    "data": {
      "BasicInfoToggle": 1,
      "camera": {
        "front_camera": "16MP",
        "rear_camera": "50MP+8MP"
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
      {"Title": "CPU", "Summary": "Snapdragon® 8 Gen 5 Mobile Platform", "Index": 0},
      {"Title": "Battery capacity", "Summary": "8300mAh (typ)", "Index": 1},
      {"Title": "Rear camera", "Summary": "50MP+8MP", "Index": 2},
      {"Title": "Screen size", "Summary": "6.83″", "Index": 3},
      {"Title": "Resolution", "Summary": "2800 x 1272", "Index": 4}
    ]
  },
  "camera": {
    "status": true,
    "data": {
      "BasicInfoToggle": 1,
      "camera": {
        "front_camera": "16MP",
        "rear_camera": "50MP+8MP"
      }
    }
  }
}'

declare -a ace6t_modules=(
	common/merge_mi_ext
	common/fix_mtp
	common/fuck_oplus_hybridzram
	common/disable_mi_vulkan
	features/fuck_audio_appname
	features/fix_oplus_lhdc
	common/disable_odm_imports
	common/fake_device_params
	common/fix_pangu
	common/fix_mi_account
	common/fix_sn
	common/enable_hyperos_features
	common/fix_camera_mr
	common/fix_face_unlock
	features/fix_nci_nfc
	features/oplus_displayfeature_bridge
	features/fix_oplus_double_tap_wake
	features/fix_ultrasonic_fingerprint
	features/oplus_millet_core_bridge
	common/fix_vendor_avc
	common/fix_launcher
	common/fix_device_identity
	common/fix_oplus_avc
	common/fix_wechat_safe_mode
	common/fix_settings_haptic
	common/fix_modem_xts
	common/fix_mi_mtp_kill_self
	features/fix_oplus_fingerprint_protocol
	common/coloros_display
	common/fix_boot_brightness
	common/fix_boot_refresh_rate
	devices/oneplus_ace6t/fix_refresh_rate_switch
	features/fix_linear_haptic
)

settings_apk_session_dir="$(mktemp -d "${TMPDIR:-/tmp}/opace6t-settings-apk.XXXXXX")"
# shellcheck disable=SC2329 # 由 EXIT trap 间接调用。
cleanup_settings_apk_session() {
	find "$settings_apk_session_dir" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup_settings_apk_session EXIT
export APK_PATCHER_SESSION_DIR="$settings_apk_session_dir"

set +e
bash "$port" "${ace6t_modules[@]}"
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
