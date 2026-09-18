#!/system/bin/sh
# ColorOS 钱包 NFC 运行时设置自动补写（features/fix_coloros_wallet）。
# 由 odm/etc/init/coloros_wallet_nfc_settings.rc 在 sys.boot_completed=1 时以
# shell 域 exec_background 调用；缺失细节见 rc 头部注释与模块 README。
settings put global nfc_multise_active "Embedded SE"
sleep 15
am broadcast -a com.nfc.action.default_pay.changed \
	-n com.finshell.wallet/com.nearme.wallet.nfc.NfcDefaultPayChangedReceiver \
	>/dev/null 2>&1
