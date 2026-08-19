#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port="$script_dir/auto_port.sh"
export DEVICE_IDENTITY_PROP=nezha_5.9.9.prop
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
bash "$port" common/merge_mi_ext \
	common/disable_mi_vulkan \
	common/disable_odm_imports \
	common/fake_device_params \
	common/fix_pangu \
	common/fix_mi_account \
	common/enable_hyperos_features \
	common/fix_camera_mr \
	common/fix_face_unlock \
	common/fix_displayfeature_bridge \
	common/fix_vendor_avc \
	common/fix_launcher \
	common/fix_device_identity \
	common/fix_boot_refresh_rate \
	common/fix_nfc \
	common/fix_wechat_safe_mode \
	common/fix_settings_haptic \
	common/fix_modem_xts \
	common/fix_mtp \
	common/fix_mi_mtp_kill_self \
	common/fix_oplus_fingerprint_protocol \
	devices/oneplus15/fix_auto_brightness \
	devices/oneplus15/fix_refresh_rate_switch \
	devices/oneplus15/fix_fingerprint \
	devices/oneplus15/fix_linear_haptic
