#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port="$script_dir/port_main.sh"
ace6_config_dir="$script_dir/devices/oneplus_ace6/config"
# 一加 Ace 6 流程明确选用的可选 SKU 附加配置；缺失时只警告并继续。
# 参考流程在澎湃 OS 4 原包上未启用该项，需要时取消注释并确认原包内存在同名文件。
# export DEVICE_IDENTITY_PROP=nezha_5.9.9.prop
# 一加 Ace 6 组合流程固定覆盖原包机型显示名。
export DEVICE_DISPLAY_NAME='OnePlus Ace 6'
# 物理 Display ID（common/fix_boot_brightness 的 ace6 Profile 消费，Ace 6 实测 dumpsys uniqueId）。
export PORT_TARGET_DISPLAY_ID="4630947185118785939"
# 底包显示 Target（Ace 6 = sun）：fix_boot_refresh_rate 只收集该 Target 的
# PanelResolution，避免混入 Ace 6 底包中其他平台（anorak 7104x3840）的分辨率。
export PORT_DISPLAY_TARGET=sun
# 自动亮度接入 OP15 同款 ColorOS displayconfig 方案：common/coloros_display 按
# Ace 6 Profile 用 my_product 的 P_7 官方表生成原生 autoBrightness 配置。
export COLOROS_DISPLAY_PROFILE=ace6
# 开机默认亮度由 common/fix_boot_brightness 的 Ace 6 Profile 安装；Overlay 与校验
# 文件都在模块 profiles/ace6/ 内，作为机型专属预编译产物提供。
export BOOT_BRIGHTNESS_PROFILE=ace6
export DISPLAY_POLICY_ODM_PROPERTIES_FILE="$ace6_config_dir/display_odm.props"
export DISPLAY_POLICY_VENDOR_PROPERTIES_FILE="$ace6_config_dir/display_vendor.props"
# 小爱唤醒机型参数：odm.prjname=24851（底包 ro.separate.soft / odm/etc/fingerprint.json），
# 声学属性额外经 /odm/etc/24851/build.gsi.prop 走 import 链生效。
export XIAOAI_WAKEUP_PROPERTIES_FILE="$ace6_config_dir/xiaoai_wakeup.props"
# Ace 6 是 SM8750（Target sun），保留 ADSP 热唤醒路线，不启用 CPU FlexKws 前端；
# APK 静态植入仍需要（小米互联 bindService 的 SecurityException 兜底已真机确认必需）。
# 锁定项与原包 VoiceTrigger.apk 的 versionCode 强绑定，版本漂移会硬失败而不是静默出坏包。
export XIAOAI_VOICETRIGGER_PATCH=true
# 运行时设备代号：启用 ColorOS 钱包后，fix_coloros_wallet 把 odm.device 改为 Ace 6 底包真值
# OP6113L1（DNA_ace6 底包 odm/etc/fingerprint.json device=OP6113L1、model=PLQ110），
# Build.DEVICE 随之变化。miui FeatureParser 按 Build.DEVICE 查找
# product/etc/device_features/<代号>.xml，common/fix_device_identity 据此把原包机型 XML 改名为
# OP6113L1.xml；小爱 cloudControl.device 白名单与钱包 fdid 校验都必须与其保持一致。
export RUNTIME_DEVICE_CODE=OP6113L1
# 小爱 cloudControl.device 白名单必须等于运行时 Build.DEVICE（启用钱包后=OP6113L1）。
export XIAOAI_VOICEASSIST_DEVICE_CODE=OP6113L1
# Ace 6 的 NFC 芯片为青藤 THN31（TMS 栈），由 features/fix_nfc_tms_bridge
# 消费本文件；NXP 专用适配 features/fix_nci_nfc 对 Ace 6 不适用。
export NFC_PROPERTIES_FILE="$ace6_config_dir/nfc.props"
# ColorOS 钱包机型身份真值（features/fix_coloros_wallet 消费）；device=OP6113L1 与
# 上方 RUNTIME_DEVICE_CODE、XIAOAI_VOICEASSIST_DEVICE_CODE 必须一致。
export WALLET_IDENTITY_PROPERTIES_FILE="$ace6_config_dir/wallet_identity.props"
export LINEAR_HAPTIC_PROPERTIES_FILE="$ace6_config_dir/linear_haptic.props"
export LINEAR_HAPTIC_MOTOR_TYPE=linear
# Ace 6 底包 rc 走 mtp.gs0 纯触发器，与模块内置的一加 15 rc（use_ffs_mtp 形态）不同，
# 由 fix_mtp 自适应校验并以这份真底包 rc 替换被原包覆盖的目标。
# 该文件与 Ace 6T 底包 rc 逐字节一致，但各机型入口仍分别指向自己的 config 目录。
export FIX_MTP_SOURCE_RC="$ace6_config_dir/init.usb.configfs.rc"
# Millet 核心桥按 KMI 选择仓库内预编译 KO；Ace 6 底包 vendor_dlkm .ko vermagic 实测为
# 6.6.89-android15-8-o-…-4k，属 android15-6.6 族（与 6T 的 android16-6.12 不同）；入口以
# KMI=android15-6.6 选择本仓库用 DDK 编译的 prebuilt/android15-6.6/millet_core.ko（vermagic 6.6）。
# KO 只匹配内核 vermagic，与 Android 版本无关；底包 vermagic 变化时需用 KMI=android15-6.6 重建。
export KMI='android15-6.6'
# Ace 6 实机超声波指纹硬件快照。通用模块不从小米原包推断这些参数；
# 传感器中心等坐标属换算估算值，刷机后如对不上可直接修改 fingerprint.props 重跑。
export ULTRASONIC_FP_PROPERTIES_FILE="$ace6_config_dir/fingerprint.props"
# Ace 6 Oplus HBP 双击亮屏参数；初始值沿用一加 15 同平台触控栈，实机需校准。
export OPLUS_DOUBLE_TAP_PROPERTIES_FILE="$ace6_config_dir/double_tap_wake.props"

# 一加 Ace 6 目标设备参数展示（Settings 设备参数缓存）。
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
      {"Title": "处理器", "Summary": "骁龙8至尊版移动平台", "Index": 0},
      {"Title": "电池容量", "Summary": "7800mAh(典型)", "Index": 1},
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
      {"Title": "CPU", "Summary": "Snapdragon® 8 Elite Mobile Platform", "Index": 0},
      {"Title": "Battery capacity", "Summary": "7800mAh (typ)", "Index": 1},
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

declare -a ace6_modules=(
	common/merge_mi_ext
	common/fix_mtp
	common/fuck_oplus_hybridzram
	common/disable_mi_vulkan
	# HyperOS iorapd 依赖底包内核没有的 /dev/iorap_dev，不关会无限重启环。
	common/disable_hyperos_preread
	# 底包 qguard 缺 libbase.so、syshealthmon-service 触 seccomp 收 SIGSYS，两者每 5 秒被 init
	# 重拉成崩溃环；只读预检后按需下发 disable，服务不存在则整体跳过（与真我 Neo8 同款处理）。
	common/disable_oplus_crash_loop
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
	# Millet 核心桥：KMI=android15-6.6（Ace 6 内核 6.6），仓库已编译对应 KO。
	features/oplus_millet_core_bridge
	# Ace 6 底包 vendor 缺 plat_sepolicy_vers.txt/genfs_labels_version.txt，需在 fix_vendor_avc
	# 之前补齐（6T/Neo8 底包不缺，无此步）。
	devices/oneplus_ace6/fix_vendor_selinux_files
	common/fix_vendor_avc
	common/fix_launcher
	common/fix_device_identity
	# 人脸特性 XML 补丁目标是运行时代号命名的机型 XML（启用钱包后由 RUNTIME_DEVICE_CODE
	# 改名为 OP6113L1.xml，改名由 fix_device_identity 完成），因此必须位于 fix_device_identity 之后。
	common/fix_face_unlock
	# ColorOS 钱包五件套；身份键经 WALLET_IDENTITY_PROPERTIES_FILE 提供，在 fix_device_identity
	# 之后把 odm 身份修正为 Ace 6 真值 OP6113L1。prebuilt 为共享产物（Ace 6T 提取），缺失则整体跳过。
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
	devices/oneplus_ace6/fix_refresh_rate_switch
	features/fix_linear_haptic
)

settings_apk_session_dir="$(mktemp -d "${TMPDIR:-/tmp}/opace6-settings-apk.XXXXXX")"
# shellcheck disable=SC2329 # 由 EXIT trap 间接调用。
cleanup_settings_apk_session() {
	find "$settings_apk_session_dir" -depth -delete >/dev/null 2>&1 || true
}
trap cleanup_settings_apk_session EXIT
export APK_PATCHER_SESSION_DIR="$settings_apk_session_dir"

set +e
bash "$port" "${ace6_modules[@]}"
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
