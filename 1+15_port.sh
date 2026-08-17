#!/bin/bash
set -euo pipefail

script_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
port="$script_dir/auto_port.sh"
export DEVICE_IDENTITY_PROP=nezha_5.9.9.prop
bash "$port" common/merge_mi_ext \
	common/disable_mi_vulkan \
	common/disable_odm_imports \
	common/fix_pangu \
	common/fix_mi_account \
	common/enable_hyperos_features \
	common/fix_camera_mr \
	common/fix_face_unlock \
	common/fix_displayfeature_bridge \
	common/fix_launcher \
	common/fix_device_identity \
	common/fix_boot_refresh_rate \
	common/fix_nfc \
	common/fix_wechat_safe_mode \
	common/fix_settings_haptic \
	common/fix_modem_xts \
	common/fix_mtp \
	common/fix_oplus_fingerprint_protocol \
	devices/oneplus15/fix_auto_brightness \
	devices/oneplus15/fix_refresh_rate_switch \
	devices/oneplus15/fix_fingerprint \
	devices/oneplus15/fix_linear_haptic
