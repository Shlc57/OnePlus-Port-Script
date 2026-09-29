# 真我 Neo8 模块与硬件参数

本目录保存由 `RealmeNeo8_port.sh` 显式传给共享模块的真我 Neo8 硬件参数，以及本机型
专属补丁。Neo8 与一加 Ace 6T 同 SoC（第五代骁龙 8 / SM8845，显示 Target `canoe`）、
同小米 17 澎湃 OS 4 原包。面板/指纹/规格类参数已由 **Neo8 原系统（ColorOS 16）真机采集**
核对（见文末“待核对参数的采集方式”），不再以 Ace 6T 估算值为准；仍依赖运行时环境的项（如
双击亮屏的 sysfs 节点、感应区尺寸）保留待校说明。

## 机型基本信息

| 项目 | 值 |
| --- | --- |
| 市场名 | 真我Neo8（`ro.vendor.oplus.market.name`，底包 `ro.vendor.oplus.market.enname`=realme Neo8） |
| 型号 / 代号 / 品牌 | `RMX8899` / `RE6402L1` / realme（`ro.build.fingerprint`=realme/RMX8899/RE6402L1:16/BP2A.250605.015） |
| 处理器 | 第五代骁龙 8（`ro.soc.model=SM8845`），显示 Target `canoe` |
| 内核 | 真机 `uname -r` = **6.12.38-android16-5-g844001fb8721-ab14552068-4k**（与底包 vermagic 一致的 android16-6.12；Millet 核心桥已启用） |
| 屏幕 | 原生 mode **1272x2772**，另有 1080x2354 降档（真机当前活动 modeId 8 = 1080x2354@90）；刷新率真机实测 **60/90/120/144/165Hz** 五档、`peak_refresh_rate=165.0`；物理 dpi 386.36618x380.8382（≈ 6.78″） |
| 物理 Display ID | 原系统实测 `local:4630947144591310483`；底包 `vendor/etc/displayconfig` 的 5 个候选均不含此值（仍待 DSU 复核） |
| 指纹 | 屏下**超声波**（3D），真机 `sensor_type=ultrasonic`、`fp_id=G_DOLPHIN_GUM_uff`（Goodix）、AIDL HAL；中心坐标 `636::2058`、`iconsize=195`、`sensorrotation=77.5` |
| 官方宣传参数 | 电池 `charge_full_design=8000000µAh`≈8000mAh、后摄 `backCamSize=50MP+8MP+50MP`、前摄 16MP |
| 高频 PWM | `ro.vendor.oplus.sensor.high_pwm_rgb=true`，传感器列表含 `Oplus High_pwm Light/CCT Sensor`、`Oplus Flicker Sensor`；`mPWMBacklightSupport=false` |
| 自动亮度表 | `display_brightness_config_P_1.xml`（真机整树只找到这一个面板表，无 `multimedia_display_brightness_config.xml` lux 表） |

## 专属模块

| 模块 | 改动分区 | 说明 |
| --- | --- | --- |
| 自动亮度接入（[`common/coloros_display`](../../common/coloros_display/README.md)，Profile `neo8`） | `odm`、`product`、`system`、`system_ext`、`vendor`、`my_product` | 用 my_product 的 P_1 面板表迁移显示 RRO（25602 android+oplus）与 FusionLight（Main_0_3、Main_2_3）；禁用 `high_pwm_rgb`。因缺 lux 表，暂不生成 `autoBrightness`（模块 warn 后保留底包 displayconfig）。需解包 `my_product`。 |
| 开机亮度（[`common/fix_boot_brightness`](../../common/fix_boot_brightness/README.md)，Profile `neo8`） | `product` | 安装启动亮度 Overlay 并移除 `MiuiFrameworkResOverlay.apk`。Overlay 浮点值暂沿用 Ace 6T（0.394047439），待实机核对。 |
| [`fix_refresh_rate_switch`](fix_refresh_rate_switch/README.md) | `product`、`system_ext` | DC/PWM 与刷新率切换修补，原假设的 165Hz 五档已由 Neo8 原系统真机确认（60/90/120/144/165），但面板尺寸与 Ace 6T 不同（2772 而非 2800），DC/PWM 补丁内容仍需实机核对。 |
| [`fix_mtp_qti`](fix_mtp_qti/README.md) | `vendor`、`system` | Qti MTP 适配（两步必须成对）：置 `vendor.usb.use_ffs_mtp=0` 让 MTP 统一走 kernel `mtp.gs0`，与 HyperOS 框架一致。Neo8 原系统真机已确认前提：`vendor.usb.use_ffs_mtp=1`、`sys.usb.config/state=mtp,adb`、`configfs=1`、存在 `/dev/usb-ffs/mtp` 与 `ffs.mtp` gadget function。因 `common/fix_mtp`（换 system rc）在 Neo8 上是 no-op，机制/目标不同而独立成模块。**只做第一步会在真机上“USB 用途只剩仅充电”**：真机无 `ro.boot.ramdump`，而 HyperOS 原包 system rc 的 `mtp`/`mtp,adb` 装配分支被 MIUI 加了该门；底包对纯 mtp 又只写了 `use_ffs_mtp=1` 的 ffs 分支，两侧就都不挂 function。因此模块同时把两条触发器的门改为 `vendor.usb.use_ffs_mtp=0`（`ptp`/`ptp,adb` 本就无门）。枚举与读文件仍待 DSU 验证。 |

## 共享模块参数

| 配置 | 消费模块 | 用途 | 状态 |
| --- | --- | --- | --- |
| `config/display_odm.props`、`display_vendor.props` | `common/fix_boot_refresh_rate` | 其余显示与触控策略；刷新率数值属性由底包按 `PORT_DISPLAY_TARGET=canoe` 自动生成。 | 沿用同 SoC Ace 6T，待实机核对 |
| `config/nfc.props` | `features/fix_nfc_tms_bridge` | Xiaomi NFC 上层兼容属性（`ro.vendor.nfc.*`）。 | 阵营已真机确认（见下节）；这些键原厂为 0 条，需由本包注入，点亮仍待 DSU |
| `config/linear_haptic.props` + `LINEAR_HAPTIC_MOTOR_TYPE=linear` | `features/fix_linear_haptic` | `sys.haptic.*` 映射与开机马达类型。 | 沿用 Ace 6T，待实机核对（原机 `sys.haptic.*` 为 0 条，aw8697 固件带 160–180Hz 谐振频率系列） |
| `config/fingerprint.props` | `features/fix_ultrasonic_fingerprint` | 超声波指纹参考坐标、区域、协议与延迟；`ultrasonic.fp.target=canoe` 过滤底包多平台分辨率。 | 参考分辨率/中心/图标尺寸已真机回填；仅 `sensor.area.*` 仍为估算待校 |
| `config/double_tap_wake.props` | `features/fix_oplus_double_tap_wake` | Oplus HBP 节点、TouchFeature 能力位与 WAKE keylayout 参数。 | 部分待校：真机有 `touchpanel`（input4）与 `oplus_fp_input`，但在 `/sys` 深度 5 内**未找到** `sec_touch`/`4100`/`4101`；“未找到”不等于不存在，需更深探测或在 DSU 实校后确认 `gesture_*_node` 与 `scan_code=62` |
| `FACE_UNLOCK_SUPPORT_TEE=false` | `common/fix_face_unlock` | 机型能力声明：本底包走**非 TEE** 人脸通路，不把原包（nezha）XML 的 `support_tee_face_unlock=true` 带过来。 | **真机已复现“能录入、解锁恒失败”**：底包 HAL `...face@1.0-service_uff` 无 `setAuthenticator`/`resetAuthentication`（仅 `getAuthenticatorId`），依赖 `osense`/`uah` 与已随 ColorOS system 消失的 `com.oplus.facerecognition`、`oiface`/`oplusoiface`（DSU 上 `Can't find service`，原系统 `init.svc.oiface` 在跑）；DSU `dumpsys face` 中 `sensorId=4` 全部 `wasSuccessful=false`。置 false 后的效果待 DSU 验证 |
| `config/xiaoai_wakeup.props`（经 `XIAOAI_WAKEUP_PROPERTIES_FILE`） | `features/fix_xiaoai_wakeup` | `odm.prjname=25602`、`pal_concurrent_capture=true`，以及 `xiaoai_cpu_kws=true`：与 Ace 6T 同方案，免手唤醒走原包自带的 CPU FlexKws 前端（不经 ADSP L1，常驻 `AudioRecord`+`libflexkws`+声纹判定，检出后走原生唤醒入口投递）；`support_record_type=-1` 是该路线必需的采集格式开关（单声道 int16）。 | **未在 Neo8 真机验证**（同栈推导，DSP 路线已定层为不可达）；让麦/间隔/窗口已参数为 `xiaoai_cpu_kws_hold_ms`、`xiaoai_cpu_kws_gap_ms`、`xiaoai_cpu_kws_window_sec`（默认 5000/1500/6），真机发现节奏不合适直接改本文件 |
| `PORT_TARGET_DISPLAY_ID` | `common/coloros_display`、`common/fix_boot_refresh_rate` | Android framework 主屏物理 Display ID。 | 原系统实测 4630947144591310483（已写为默认，仍可覆盖）；**DSU 值才是最终权威** |
| `COLOROS_DISPLAY_PROFILE=neo8`、`BOOT_BRIGHTNESS_PROFILE=neo8` | `common/coloros_display`、`common/fix_boot_brightness` | 显式锁定机型 Profile。Target `canoe` 与 Ace 6T 相同，自动匹配会先命中 ace6t，因此**必须显式指定**。 | 实测 |
| `XIAOAI_VOICEASSIST_DEVICE_CODE=RE6402L1` | `features/fix_xiaoai_wakeup` | 等于运行时 `Build.DEVICE`；启用钱包后 `odm.device` 由 nezha 改 RE6402L1，须与 `RUNTIME_DEVICE_CODE`/钱包身份一致。 | 与底包真值一致 |
| `WALLET_IDENTITY_PROPERTIES_FILE=config/wallet_identity.props` | `features/fix_coloros_wallet` | 钱包机型身份真值（`brand=realme`、`cuptsm=REALME\|ESE\|01\|27`、`device=RE6402L1`、`model/name=RMX8899`、`marketname=真我Neo8`）；钱包不再写死 OnePlus。 | 底包实测 |

## NFC 方案：THN31/TMS 桥（与 Ace 6 共用）

Neo8 底包取证（`DNA_neo8`）确认控制器为青藤 **THN31（TMS 栈）**：`odm/etc/nfc/nfc_fw_ref`
中 project 25602 落在 `thn31_fw_*` 行；odm 自带 `android.hardware.nfc-service-tms`（标准
`android.hardware.nfc.INfc` AIDL）+ `manifest_nfc_thn31.xml` + `nfc_nci.thn31nfc.tms.so` +
`/dev/tms_nfc`，但缺 NXP HAL 三项契约。**Neo8 原系统真机已印证同一结论**：`/dev/tms_nfc`
存在（`crw-rw---- nfc nfc`），init 里同时定义 `nfc_hal_service`（指向 `/vendor/bin/hw/android.hardware.nfc-service-st`
但 chmod/chown 的是 `/dev/tms_nfc`，即典型“ST 命名残留”陷阱）与 `nfc_hal_service.tms.aidl`
（`/odm/bin/hw/android.hardware.nfc-service-tms`）；`dumpsys -l` 有 `android.hardware.nfc.INfc/default`
与 `nfcextnsservice`，**没有** `vendor.nxp.nxpnfc_aidl.INxpNfc`（Ace 6T 反而有，再次证明不能凭
单个服务/文件存在判阵营）。因此 NFC 与 Ace 6 共用
[`features/fix_nfc_tms_bridge`](../../features/fix_nfc_tms_bridge/README.md)：保留小米 MIUI
签名的 Nfc_st（含其自带 NCI 栈），注入 `/dev/st21nfc`/`/dev/nq-nci`→`/dev/tms_nfc` 节点别名
 + TMS HAL 最小 SELinux bundle。另需注意：原厂 `ro.vendor.nfc.*` 为 0 条（Ace 6T 有 7 条
 `ro.vendor.nfc.support.*`），所以 `config/nfc.props` 里的上层兼容开关必须由本包注入。

不用 `features/fix_nci_nfc`（NXP 专用，底包缺 NXP 契约）；也不用通用 Transsion NfcNci
（OplusNFC 那类）：移植侧 `com.android.nfc` 为 MIUI 签名且 `sharedUserId=android.uid.nfc`、
NCI 栈（`libnfc_xm_nci_jni.so`）打包在 APK 内部，外部签名且 v3 验签失败的通用 APK 会被
PackageManager 拒装、也无法在不破签的前提下注入外部 NCI 库。故 TMS 桥是 HyperOS 上唯一
签名安全路径。本次回传时 **NFC 开关是关着的**（`dumpsys nfc` 的 `mState=off`，贴卡采样
`new_lines=243 nfc_hits=0` 因此无效），点亮仍需真机验证：请在设置里打开 NFC 后重跑采集并贴卡。
基础读卡中概率、钱包/SE 低概率。

## 组合中暂停用的模块

- `common/fix_mtp`：Neo8 底包是 Qti USB（`vendor/etc/init/hw/init.qcom.usb.rc`），没有
  该模块依赖的 `init.usb.configfs.rc`；且逐字比对证实 realme 原厂 system rc 与小米原包一致，
  换 system rc 对 Neo8 是 **no-op**。MTP 由本目录 [`fix_mtp_qti`](fix_mtp_qti/README.md)
  以“`vendor.usb.use_ffs_mtp=0` + 放开 HyperOS system rc 的 `ro.boot.ramdump` 门”两步适配，
  不再使用 `common/fix_mtp`。

（Millet 核心桥原为暂停用；KMI 底包实测 `android16-6.12` 后与仓库预编译 KO 匹配，已接回组合，仍需刷机验证。）

## 钱包（已启用，含遗留风险）

`features/fix_coloros_wallet` 已接回组合；身份键改为读本目录 `config/wallet_identity.props`
（realme 真值：`brand=realme`、`cuptsm=REALME|ESE|01|27`、`device=RE6402L1`），启用后
`odm.device` 变为 RE6402L1，故 `RUNTIME_DEVICE_CODE`/`XIAOAI_VOICEASSIST_DEVICE_CODE` 已同步，
机型 XML 由 fix_device_identity 改名为 RE6402L1.xml。**遗留风险**：五件套 prebuilt APK 目前
仍是 Ace 6T 底包提取产物，正式启用前应从 Neo8 底包 `system.img` 重新提取替换
`features/fix_coloros_wallet/prebuilt/`（缺失则整体跳过）；且钱包/SE 依赖 NFC，Neo8 NFC 为
 THN31（见上），冷包下钱包支付链路大概率不通。均未真机验证。

## 待核对参数的采集方式

上面标为“待实测/待核对”的硬件事实由 [`tools/device_probe.sh`](../../tools/device_probe.sh) 在手机端直接
采集：MT 管理器可执行、不依赖 adb、全程只读（仅 `su` 提权与写自己的输出目录）。已在 Ace 6T 原系统
（ColorOS 16，root）真机跑通。产出 `device_probe_stock.zip`（无 zip 时退化 `tar.gz`）三件套：

- `SUMMARY.txt`：脚本自动提炼的关键结论。实测可自动拿到的有：市场名与 `ro.vendor.oplus.camera.backCamSize/frontCamSize`
  （官方宣传摄像头像素）、`charge_full_design`（电池 mAh）、`dumpsys display` 里的物理分辨率/dpi/档位 fps
  （直接判定是否 165Hz 五档）、高频 PWM 证据（`ro.vendor.oplus.sensor.high_pwm_rgb` + High_pwm/Flicker 传感器）、
  `persist.vendor.fingerprint.sensor_type` 与 `persist.vendor.fingerprint.optical.sensorlocation`（超声波指纹中心坐标，
  配合 `fingerprint_pressed_icon_size` / `fingerprint_icon_margin_bottom`）、`double_tap_to_wake` 开关值、
  `dumpsys nfc` 的 `mState`、`sys.usb.config/state` 与 `vendor.usb.use_ffs_mtp`（原厂 MTP 走 ffs 还是 kernel）。
- `captures/`：全量 `getprop`、关键 `settings list` 过滤行（避开几百 KB 白名单）、display/fingerprint/nfc/usb/sensors
  等 `dumpsys`（ColorOS 的振动服务名是 `vibrator_manager`，不是 `vibrator`）、触控 `getevent -p` 与 HBP 节点探测、
  亮度 sysfs、关键分区文件存在性，以及 NFC 贴卡与 USB 用途切换两段带提示的采样（`--no-pause` 可跳过，`--pause 秒` 可调时长）。
- `MANUAL.txt`：只留机器拿不到的三类——主观观感、需要外部条件（卡/电脑/耳机/暗光）、界面文案。填完 `--pack` 重打包。

脚本不验证任何补丁效果；`PORT_TARGET_DISPLAY_ID`、冷启动 avc 与崩溃日志仍必须以 DSU 环境采集结果为准。

### Neo8 回传核对结果（tag=stock，脚本 2026.09.23-2）

已据此回填仓库的：面板原生 1272x2772 与 165Hz 五档、Display ID 4630947144591310483、
超声波指纹中心 636::2058 与 `iconsize=195`、电池 8000mAh、后摄 50MP+8MP+50MP、
KMI（`uname -r`=6.12.38-android16-5-…-4k）、TMS 阵营与 `/dev/tms_nfc`、原厂 `use_ffs_mtp=1`。

仍缺的（本次未能定案）：
- 人脸解锁：已复现“能录入但解不开”（原因与处置见上表 `FACE_UNLOCK_SUPPORT_TEE`），
  置 false 后的效果需下一次 DSU 回传确认（采集脚本已增加“锁屏→人脸解锁”日志采样）。
- NFC 开关未开（`mState=off`），贴卡采样无效，需开 NFC 重跑一次。
- `MANUAL.txt` 测试者未填：主观观感、双击实测、人脸 2D/3D 文案、LHDC 列表、界面档位名仍空。
- `sec_touch`/`4100`/`4101` 节点在 `/sys` 深度 5 内未找到（探测深度不够，不是否定结论），下一版脚本需对
  `touchpanel` 所在 input 目录整目次探测。
- 1080x2354 为当前活动降档模式，DSU 下 HyperOS 可能默认抬到 1272x2772，刷新率/分辨率验证时要同时看
  `dumpsys display` 的 activeMode。

这些参数依赖实际运行设备，不能从小米原包推断。更换底包、面板、指纹模组、触控驱动或
SKU 后必须重新核对，不能直接照搬一加 15、一加 Ace 6/6T。`RealmeNeo8_port.sh` 会按固定
顺序组合 `common`、`features` 与本目录模块，并保证 SELinux 业务模块先于
`common/fix_vendor_avc` 安装。不要只根据本目录参数推断整套流程。
