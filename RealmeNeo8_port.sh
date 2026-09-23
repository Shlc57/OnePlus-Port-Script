#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port="$script_dir/port_main.sh"
neo8_config_dir="$script_dir/devices/realme_neo8/config"
# 真我 Neo8 流程明确选用的可选 SKU 附加配置；缺失时只警告并继续。
# 参考流程在澎湃 OS 4 原包上未启用该项，需要时取消注释并确认原包内存在同名文件。
# export DEVICE_IDENTITY_PROP=nezha_5.9.9.prop
# 真我 Neo8 组合流程固定覆盖原包机型显示名（底包 ro.vendor.oplus.market.enname）。
export DEVICE_DISPLAY_NAME='realme Neo8'
# 物理 Display ID（common/coloros_display 的 neo8 Profile 消费）。Neo8 底包
# vendor/etc/displayconfig 有 5 个同模板的候选 display_id_*.xml，静态无法确定主屏；
# 这里默认取首个候选，必须由真机 `dumpsys display | grep -m1 uniqueId` 核对后覆盖
# （与一加 15 入口一致的“可被环境覆盖的具体值”约定）。未核对前不要当作已确认生效。
export PORT_TARGET_DISPLAY_ID="${PORT_TARGET_DISPLAY_ID:-4630946850534658451}"
# 底包显示 Target（Neo8 = canoe，SM8845 第五代骁龙 8，与 Ace 6T 同 SoC）：
# fix_boot_refresh_rate 只收集该 Target 的 PanelResolution，避免混入其他平台面板分辨率。
export PORT_DISPLAY_TARGET=canoe
# 自动亮度接入 OP15/Ace 6T 同款 ColorOS displayconfig 方案：common/coloros_display 按
# Neo8 Profile 用 my_product 的 P_1 官方表生成显示配置。Target 与 Ace 6T 同为 canoe，
# 自动匹配会先命中 ace6t，因此必须显式锁定 neo8 Profile。
export COLOROS_DISPLAY_PROFILE=neo8
# 开机默认亮度由 common/fix_boot_brightness 的 Neo8 Profile 安装；Overlay 与校验文件都在
# 模块 profiles/neo8/ 内。Overlay 浮点值暂沿用同 SoC 的 Ace 6T（0.394047439），待实机核对。
export BOOT_BRIGHTNESS_PROFILE=neo8
export DISPLAY_POLICY_ODM_PROPERTIES_FILE="$neo8_config_dir/display_odm.props"
export DISPLAY_POLICY_VENDOR_PROPERTIES_FILE="$neo8_config_dir/display_vendor.props"
# 小爱唤醒机型参数：odm.prjname=25602（底包 fingerprint.json / ro.separate.soft 实测），
# 声学属性经 /odm/etc/<prjname>/build.gsi.prop 走 import 链生效。
export XIAOAI_WAKEUP_PROPERTIES_FILE="$neo8_config_dir/xiaoai_wakeup.props"
export XIAOAI_PAL_CONFIG_FILE="mi_odm/etc/audio/sku_canoe/resourcemanager_canoe_mtp.xml"
# 运行时设备代号：启用 fix_coloros_wallet 后，钱包把 odm.device 改为 Neo8 底包真值
# RE6402L1（Build.DEVICE 随之变化）。miui FeatureParser 按 Build.DEVICE 查找
# product/etc/device_features/<代号>.xml，由 common/fix_device_identity 据
# RUNTIME_DEVICE_CODE 把原包 nezha.xml 改名为 RE6402L1.xml；小爱 cloudControl.device
# 白名单与钱包 fdid 校验都必须与其一致。
export RUNTIME_DEVICE_CODE=RE6402L1
# 当前 APK 补丁仅依据 SM8845 原包（nezha）分析，Neo8 与 Ace 6T 同原包，显式启用。
export XIAOAI_VOICETRIGGER_PATCH=true
# 小爱 cloudControl.device 白名单必须等于运行时 Build.DEVICE（启用钱包后=RE6402L1）。
export XIAOAI_VOICEASSIST_DEVICE_CODE=RE6402L1
# NFC：Neo8 底包为青藤 THN31（TMS 栈），改用 features/fix_nfc_tms_bridge（与 Ace 6 共用）：
# 保留小米 MIUI 签名的 Nfc_st（含其自带 NCI 栈）+ /dev/tms_nfc→st21nfc/nq-nci 节点别名 +
# TMS HAL 最小 SELinux。不再用 NXP 专用 features/fix_nci_nfc（底包缺 NXP HAL 契约）；
# 通用 Transsion NfcNci 因 android.uid.nfc 绑 MIUI 密钥、外部签名且 v3 验签失败，无法在
# HyperOS 移植上装用（详见机型 README）。ro.vendor.nfc.* 兼容属性由桥消费。
export NFC_PROPERTIES_FILE="$neo8_config_dir/nfc.props"
# ColorOS 钱包机型身份真值（features/fix_coloros_wallet 消费）；device=RE6402L1 必须与
# 上方 RUNTIME_DEVICE_CODE、XIAOAI_VOICEASSIST_DEVICE_CODE 一致。
export WALLET_IDENTITY_PROPERTIES_FILE="$neo8_config_dir/wallet_identity.props"
export LINEAR_HAPTIC_PROPERTIES_FILE="$neo8_config_dir/linear_haptic.props"
export LINEAR_HAPTIC_MOTOR_TYPE=linear
# MTP：Neo8 底包是 Qti USB（vendor/etc/init/hw/init.qcom.usb.rc），没有 common/fix_mtp
# 依赖的 init.usb.configfs.rc；且逐字比对证实 realme 原厂 system rc 与小米原包一致，换
# system rc 对 Neo8 是 no-op。真因是 vendor 走 ffs.mtp(use_ffs_mtp=1) 而 HyperOS 框架走
# kernel mtp.gs0。由 devices/realme_neo8/fix_mtp_qti 置 vendor.usb.use_ffs_mtp=0 统一到
# kernel mtp.gs0（详见该模块 README），故不接入 common/fix_mtp。
# Millet 核心桥按 KMI 选择仓库内预编译 KO；Neo8 内核已底包实测：vendor_dlkm 全部 .ko
# 与 boot/kernel vermagic 均为 android16-6.12（与 Ace 6T/一加 15 同 KMI），仓库有对应
# prebuilt/android16-6.12/millet_core.ko，故启用 millet（仍需刷机验证）。
export KMI='android16-6.12'
# Neo8 超声波指纹目标设备硬件快照。通用模块不从小米原包推断这些参数；参考分辨率
# 与传感器中心暂沿用同 SoC 的 Ace 6T，属估算值，刷机前用实机量取后修改 fingerprint.props 重跑。
export ULTRASONIC_FP_PROPERTIES_FILE="$neo8_config_dir/fingerprint.props"
# Neo8 Oplus HBP 双击亮屏参数；初始值沿用同 SoC 触控栈，实机需校准。
export OPLUS_DOUBLE_TAP_PROPERTIES_FILE="$neo8_config_dir/double_tap_wake.props"

# 真我 Neo8 目标设备参数展示（Settings 设备参数缓存）。
# 处理器为底包实测（第五代骁龙 8 / SM8845）；电池、摄像头、尺寸、分辨率暂沿用同 SoC
# 的 Ace 6T 数值，属待核对项，正式宣传参数需按 realme Neo8 官方规格回填。
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

declare -a neo8_modules=(
	common/merge_mi_ext
	# Qti MTP：置 vendor.usb.use_ffs_mtp=0，统一走 kernel mtp.gs0（common/fix_mtp 在此是 no-op）。
	devices/realme_neo8/fix_mtp_qti
	common/fuck_oplus_hybridzram
	common/disable_mi_vulkan
	# HyperOS iorapd 依赖底包内核没有的 /dev/iorap_dev，不关会无限重启环。
	common/disable_hyperos_preread
	features/fuck_audio_appname
	features/fix_oplus_lhdc
	common/disable_odm_imports
	common/fake_device_params
	common/fix_pangu
	common/fix_mi_account
	features/fix_xiaoai_wakeup
	common/fix_sn
	common/enable_hyperos_features
	common/fix_camera_mr
	features/fix_nfc_tms_bridge
	features/oplus_displayfeature_bridge
	features/fix_oplus_double_tap_wake
	features/fix_ultrasonic_fingerprint
	# Millet 核心桥：KMI 已实测 android16-6.12，与仓库预编译 KO 匹配（Ace 6T 同 KMI）。
	features/oplus_millet_core_bridge
	common/fix_vendor_avc
	common/fix_launcher
	common/fix_device_identity
	# 人脸特性 XML 补丁目标是运行时代号命名的机型 XML（启用钱包后由 RUNTIME_DEVICE_CODE
	# 改名为 RE6402L1.xml，改名由 fix_device_identity 完成），因此位于 fix_device_identity 之后。
	common/fix_face_unlock
	# ColorOS 钱包五件套；身份键由 devices/realme_neo8/config/wallet_identity.props
	# （brand=realme、cuptsm=REALME|ESE|01|27 等真值）经 WALLET_IDENTITY_PROPERTIES_FILE 提供，
	# 在 fix_device_identity 之后把 odm 身份修正为 Neo8 真值。注意：prebuilt 五件套目前仍是
	# Ace 6T 提取产物，正式启用前应改从 Neo8 底包 system 重新提取（缺失则整体跳过）。
	features/fix_coloros_wallet
	common/fix_oplus_avc
	common/fix_wechat_safe_mode
	common/fix_settings_haptic
	common/fix_modem_xts
	common/fix_mi_mtp_kill_self
	features/fix_oplus_fingerprint_protocol
	common/coloros_display
	common/fix_boot_brightness
	common/fix_boot_refresh_rate
	devices/realme_neo8/fix_refresh_rate_switch
	features/fix_linear_haptic
)

settings_apk_session_dir="$(mktemp -d "${TMPDIR:-/tmp}/realmeneo8-settings-apk.XXXXXX")"
# shellcheck disable=SC2329 # 由 EXIT trap 间接调用。
cleanup_settings_apk_session() {
	find "$settings_apk_session_dir" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup_settings_apk_session EXIT
export APK_PATCHER_SESSION_DIR="$settings_apk_session_dir"

set +e
bash "$port" "${neo8_modules[@]}"
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
