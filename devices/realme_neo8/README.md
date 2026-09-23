# 真我 Neo8 模块与硬件参数

本目录保存由 `RealmeNeo8_port.sh` 显式传给共享模块的真我 Neo8 硬件参数，以及本机型
专属补丁。Neo8 与一加 Ace 6T 同 SoC（第五代骁龙 8 / SM8845，显示 Target `canoe`）、
同小米 17 澎湃 OS 4 原包，因此多数显示/触控/触感/指纹策略以 Ace 6T 为起点，但下列参数
依赖 realme 底包与真机，不能直接当作 Ace 6T 已验证值照搬。

## 机型基本信息

| 项目 | 值 |
| --- | --- |
| 市场名 | 真我 Neo8（realme Neo8，底包 `ro.vendor.oplus.market.enname`） |
| 设备代号 / OEM | `RE6402L1` / RMX8899，project（prjname）`25602` |
| 品牌 / 厂商 | realme |
| 处理器 | 第五代骁龙 8（SM8845），显示 Target `canoe` |
| 内核 | 底包实测 `android16-6.12`（`vendor_dlkm` 全部 `.ko` 与 `boot/kernel` vermagic 一致，与 Ace 6T/一加 15 同 KMI；Millet 核心桥已启用） |
| 屏幕 | 待实测；分辨率暂沿用同 SoC Ace 6T 的 1272x2800 估算 |
| 物理 Display ID | 待实测（底包 `vendor/etc/displayconfig` 有 5 个同模板候选，需 `dumpsys display` 定主屏） |
| 指纹 | 屏下**超声波**（3D）：底包实测确认（`odm/etc/permissions/oplus.fingerprint.ultrasonic_fp_support.xml` + `...fingerprint@2.1-service_uff` + `aw8697_fingerprint_effect*` 马达固件）；仅传感器**精确位置**待实机校准 |
| 自动亮度表 | `display_brightness_config_P_1.xml`（底包缺 `multimedia_display_brightness_config.xml` lux 表） |

## 专属模块

| 模块 | 改动分区 | 说明 |
| --- | --- | --- |
| 自动亮度接入（[`common/coloros_display`](../../common/coloros_display/README.md)，Profile `neo8`） | `odm`、`product`、`system`、`system_ext`、`vendor`、`my_product` | 用 my_product 的 P_1 面板表迁移显示 RRO（25602 android+oplus）与 FusionLight（Main_0_3、Main_2_3）；禁用 `high_pwm_rgb`。因缺 lux 表，暂不生成 `autoBrightness`（模块 warn 后保留底包 displayconfig）。需解包 `my_product`。 |
| 开机亮度（[`common/fix_boot_brightness`](../../common/fix_boot_brightness/README.md)，Profile `neo8`） | `product` | 安装启动亮度 Overlay 并移除 `MiuiFrameworkResOverlay.apk`。Overlay 浮点值暂沿用 Ace 6T（0.394047439），待实机核对。 |
| [`fix_refresh_rate_switch`](fix_refresh_rate_switch/README.md) | `product`、`system_ext` | DC/PWM 与刷新率切换修补，沿用一加 15/Ace 6T 的 165Hz 五档假设，与 Neo8 面板实际档位可能不符，启用前需按实机重审。 |
| [`fix_mtp_qti`](fix_mtp_qti/README.md) | `vendor` | Qti MTP 适配：置 `vendor.usb.use_ffs_mtp=0` 让 MTP 统一走 kernel `mtp.gs0`，与 HyperOS 框架一致。因 `common/fix_mtp`（换 system rc）在 Neo8 上是 no-op，机制/目标不同而独立成模块。静态分区取证确定，未真机验证。 |

## 共享模块参数

| 配置 | 消费模块 | 用途 | 状态 |
| --- | --- | --- | --- |
| `config/display_odm.props`、`display_vendor.props` | `common/fix_boot_refresh_rate` | 其余显示与触控策略；刷新率数值属性由底包按 `PORT_DISPLAY_TARGET=canoe` 自动生成。 | 沿用同 SoC Ace 6T，待实机核对 |
| `config/nfc.props` | `features/fix_nfc_tms_bridge` | Xiaomi NFC 上层兼容属性（`ro.vendor.nfc.*`）。 | 与 Ace 6 共用 TMS 桥，待实机核对 |
| `config/linear_haptic.props` + `LINEAR_HAPTIC_MOTOR_TYPE=linear` | `features/fix_linear_haptic` | `sys.haptic.*` 映射与开机马达类型。 | 沿用 Ace 6T，待实机核对 |
| `config/fingerprint.props` | `features/fix_ultrasonic_fingerprint` | 超声波指纹参考坐标、区域、协议与延迟；`ultrasonic.fp.target=canoe` 过滤底包多平台分辨率。 | 分辨率/传感器中心为估算值，实机核对后重跑 |
| `config/double_tap_wake.props` | `features/fix_oplus_double_tap_wake` | Oplus HBP 节点、TouchFeature 能力位与 WAKE keylayout 参数。 | 沿用同 SoC 触控栈，实机需校准 |
| `config/xiaoai_wakeup.props` | `features/fix_xiaoai_wakeup` | `odm.prjname=25602` 与 PAL 并发采集开关。 | project 底包实测；声学属性可见性待真机复核 |
| `PORT_TARGET_DISPLAY_ID` | `common/coloros_display`、`common/fix_boot_refresh_rate` | Android framework 主屏物理 Display ID。 | **待实测**（入口给了可覆盖的候选默认值） |
| `COLOROS_DISPLAY_PROFILE=neo8`、`BOOT_BRIGHTNESS_PROFILE=neo8` | `common/coloros_display`、`common/fix_boot_brightness` | 显式锁定机型 Profile。Target `canoe` 与 Ace 6T 相同，自动匹配会先命中 ace6t，因此**必须显式指定**。 | 实测 |
| `XIAOAI_VOICEASSIST_DEVICE_CODE=RE6402L1` | `features/fix_xiaoai_wakeup` | 等于运行时 `Build.DEVICE`；启用钱包后 `odm.device` 由 nezha 改 RE6402L1，须与 `RUNTIME_DEVICE_CODE`/钱包身份一致。 | 与底包真值一致 |
| `WALLET_IDENTITY_PROPERTIES_FILE=config/wallet_identity.props` | `features/fix_coloros_wallet` | 钱包机型身份真值（`brand=realme`、`cuptsm=REALME\|ESE\|01\|27`、`device=RE6402L1`、`model/name=RMX8899`、`marketname=真我Neo8`）；钱包不再写死 OnePlus。 | 底包实测 |

## NFC 方案：THN31/TMS 桥（与 Ace 6 共用）

Neo8 底包取证（`DNA_neo8`）确认控制器为青藤 **THN31（TMS 栈）**：`odm/etc/nfc/nfc_fw_ref`
中 project 25602 落在 `thn31_fw_*` 行；odm 自带 `android.hardware.nfc-service-tms`（标准
`android.hardware.nfc.INfc` AIDL）+ `manifest_nfc_thn31.xml` + `nfc_nci.thn31nfc.tms.so` +
`/dev/tms_nfc`，但缺 NXP HAL 三项契约。因此 NFC 与 Ace 6 共用
[`features/fix_nfc_tms_bridge`](../../features/fix_nfc_tms_bridge/README.md)：保留小米 MIUI
签名的 Nfc_st（含其自带 NCI 栈），注入 `/dev/st21nfc`/`/dev/nq-nci`→`/dev/tms_nfc` 节点别名
 + TMS HAL 最小 SELinux bundle。

不用 `features/fix_nci_nfc`（NXP 专用，底包缺 NXP 契约）；也不用通用 Transsion NfcNci
（OplusNFC 那类）：移植侧 `com.android.nfc` 为 MIUI 签名且 `sharedUserId=android.uid.nfc`、
NCI 栈（`libnfc_xm_nci_jni.so`）打包在 APK 内部，外部签名且 v3 验签失败的通用 APK 会被
PackageManager 拒装、也无法在不破签的前提下注入外部 NCI 库。故 TMS 桥是 HyperOS 上唯一
签名安全路径。NFC 是否真正点亮仍需真机验证（基础读卡中概率、钱包/SE 低概率）。

## 组合中暂停用的模块

- `common/fix_mtp`：Neo8 底包是 Qti USB（`vendor/etc/init/hw/init.qcom.usb.rc`），没有
  该模块依赖的 `init.usb.configfs.rc`；且逐字比对证实 realme 原厂 system rc 与小米原包一致，
  换 system rc 对 Neo8 是 **no-op**。MTP 由本目录 [`fix_mtp_qti`](fix_mtp_qti/README.md)
  以 `vendor.usb.use_ffs_mtp=0` 方式适配，不再使用 `common/fix_mtp`。

（Millet 核心桥原为暂停用；KMI 底包实测 `android16-6.12` 后与仓库预编译 KO 匹配，已接回组合，仍需刷机验证。）

## 钱包（已启用，含遗留风险）

`features/fix_coloros_wallet` 已接回组合；身份键改为读本目录 `config/wallet_identity.props`
（realme 真值：`brand=realme`、`cuptsm=REALME|ESE|01|27`、`device=RE6402L1`），启用后
`odm.device` 变为 RE6402L1，故 `RUNTIME_DEVICE_CODE`/`XIAOAI_VOICEASSIST_DEVICE_CODE` 已同步，
机型 XML 由 fix_device_identity 改名为 RE6402L1.xml。**遗留风险**：五件套 prebuilt APK 目前
仍是 Ace 6T 底包提取产物，正式启用前应从 Neo8 底包 `system.img` 重新提取替换
`features/fix_coloros_wallet/prebuilt/`（缺失则整体跳过）；且钱包/SE 依赖 NFC，Neo8 NFC 为
 THN31（见上），冷包下钱包支付链路大概率不通。均未真机验证。

这些参数依赖实际运行设备，不能从小米原包推断。更换底包、面板、指纹模组、触控驱动或
SKU 后必须重新核对，不能直接照搬一加 15、一加 Ace 6/6T。`RealmeNeo8_port.sh` 会按固定
顺序组合 `common`、`features` 与本目录模块，并保证 SELinux 业务模块先于
`common/fix_vendor_avc` 安装。不要只根据本目录参数推断整套流程。
