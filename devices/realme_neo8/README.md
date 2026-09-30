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
| （不传人脸参数） | `common/fix_face_unlock` | 与一加 Ace 6T 同步：本机型**不再覆盖** TEE 声明，沿用原包机型 XML 的 `support_tee_face_unlock=true`。 | **根因已推翻，现为未定案**：2026-09-30 在 Ace 6T DSU 上实测到完全同配置却能正常解锁——`OP6117L1.xml` 里同为 `support_tee_face_unlock=true`、`region_dom=ALL`、同一个 `vendor.oplus.hardware.biometrics.face@1.0-service_uff`、`oiface`/`oplusoiface` 同样 `Can't find service`、`sys.miface.auth.package=noback` 也一样，但 `prints accept=1 reject=0`、`authEndedFor(sensorId=4, strength=4095, wasSuccessful=true)`、延时 276ms。所以“HAL 缺 authenticator 接口 + oiface 不存在”**不能解释 Neo8 的解不开**；Neo8 侧现场仍是“能录入、解锁被拒”（accept=0 reject=2）。曾试过的 `FACE_UNLOCK_SUPPORT_TEE=false` 无任何取证支持（两份回传 runtime 均为 true），已从入口移除 |
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

## 与一加 Ace 6T 的组合差异

`RealmeNeo8_port.sh` 与 `OPAce6T_port.sh` 的模块**清单与执行顺序已逐项对齐**（含新加的
`common/disable_oplus_crash_loop`），只剩下列因底包事实而必须不同的四项：

| 差异 | 原因 |
| --- | --- |
| `devices/realme_neo8/fix_mtp_qti` 取代 `common/fix_mtp` | Neo8 底包是 Qti USB，没有 `init.usb.configfs.rc`，换 system rc 是 no-op（详上节）。 |
| `features/fix_nfc_tms_bridge` 取代 `features/fix_nci_nfc` | Neo8 控制器为青藤 THN31（TMS 栈），底包缺 NXP HAL 三项契约。 |
| `devices/realme_neo8/fix_refresh_rate_switch` | 机型专属副本（面板 2772 而非 2800）。 |
| `common/disable_oplus_crash_loop` 只在本组合启用 | 依据是 Neo8 真机取证（qguard / syshealthmon 崩溃环）；其他机型未取证，不默认引入。 |

入口 `export` 集合与 6T 的差异也只剩 `FIX_MTP_SOURCE_RC`（6T 专有）；`FACE_UNLOCK_SUPPORT_TEE`
已于 2026-09-30 从本组合移除，两边人脸参数路径一致。

## 2026-09-30 移植侧取证结论与已实施修复

[`tools/issue_trace.sh`](../../tools/issue_trace.sh) 两轮回传（均为**旧包**：`PortCpuKws=0`、机型 XML TEE=`true`）得到的硬证据：

- **声音“时有时无”的机制是音频服务重启环**，不是卡顿：`AIDLUtils: HAL instance died, audio server is restarting` 76 次，
  4 分钟内 `audioserver` 56 个不同 pid（约每 5 秒一次），**整段日志无一条 Fatal signal/tombstone**（而是
  `init: Service 'vendor.audio-hal-aidl' received SIGKILL` 与 `ctl.interface_start` 对 `soundtrigger3`/`audio.core.IConfig` 的
  `PROP_ERROR_HANDLE_CONTROL_MESSAGE`）。驱动者是仍在跑的 ADSP 热唤醒：48 次 `LOAD_PHRASE_MODEL`、123 次 `-22`，
  失败落在 `gsl: acdb get tags from gkv failed with 19` → `Failed to get instance id for tag c0000008` → `status -22`。
  旧包不含 CPU 前端，所以这是旧包的必然表现；**新包必须同时看到 `SENTINEL_CPU_KWS` 非 0 才能评 CPU 路线效果**。
- 已为此加**构建期产物哨兵**：`features/fix_xiaoai_wakeup` 在 `xiaoai_cpu_kws=true` 分支里校验回编译后的
  `VoiceTrigger.apk` 确实含 `PortCpuKws`，否则补丁直接失败——防止拿旧 product 产物继续出包（只影响启用该分支的机型）。
- **底包两个服务在无限重启**（与包版本无关，现在就能修）：`linker: CANNOT LINK EXECUTABLE "/vendor/bin/qguard": library "libbase.so" not found`
  （共 53 次，qguard 自身**一条日志都没输出过**；根因待定：文件真缺失还是 vendor linker namespace 解析不到，
  历史上见过 `/vendor/lib64/libbase.so` 存在）；以及 `libminijail: blocked syscall: lseek` 使
  `vendor.qti.syshealthmon-service` 收 `SIGSYS`。两者各每 5 秒重拉一次并被 init 记入 updatable 退避（同一句
  `exited 4 times in 4 minutes` 各 45 次），`sys.init.updatable_crashing_process_name` 就是 `syshealthmon-service`；
  同机 1 分钟 load 平均 9.3、峰值 11.2（MemAvailable 仍 4.6GB）。ADSP/modem 的 SSR 通知在内核侧
  `qcom_sysmon`/`qcom_pd_mapper`，**不受本修复影响**。新增 `common/disable_oplus_crash_loop` 摘掉它们，**只写进 Neo8 组合**。
- **与包版本无关、也仍在声音上的两族失败**（本轮只记录、不改代码，无可靠单变量判据）：
  `APM_AudioPolicyManager: [TF-OTHERS] checkAndSetVolume invalid volume index range in the curve` 6650 次，
  `DeviceHalAidl: parseAndSetVendorParameters Failed` 3852 次，被拒的是 HyperOS 下发的按设备音量曲线与通话参数
  （`audio_volume_stream_music_device_speaker`、`audio_volume_stream_voice_call_device_earpiece`、`call_state=…;vsid=…`、`mRingerMode`）。
  它们不是 `appname`（该补丁已验证生效：音频上下文里 `appname=` 0 命中），需要单独对比底包
  `audio_policy_configuration*` 的音量曲线与原包策略后才能动。
- **NFC 拿到首份有效证据**：`mState=on`、`/dev/st21nfc`+`/dev/tms_nfc` 在位、四个 NFC 服务全 running、avc 0 条，
  但发现层失败：`nfcManager_enableDiscovery: tech_mask = 00` 与 `startRfDiscovery: Wait for completion timeout`，
  窗口内无任何 `TARGET_DISCOVERED/NfcTag/IsoDep`；同时 `com.qualcomm.qti.xrvd.service` 在反复 `setReaderMode`。
  即“装配通、NCI 发现不通”，下一步要抓 NCI tx/rx 与固件下载（工具已加发现层定量行）。
- **其他崩溃与 avc 不属本轮缺陷**：tombstone 时间戳均为 09-27（相机 `OemLayer::RaiseSignalAbort`/`CSLAcquireDeviceHW`、
  第三方 mediaeditor/gcam、用户自装的 vtools scene-daemon）；62 条 avc 里主体是抖音/微信与 KSU 相关的
  `/dev/fuse getattr`、`netlink_route bind`，真正的移植侧缺口只有 `cameraserver → hal_face_oplus` 的 `dir search`（5 次）与
  `hal_light_default → oppo_block_device` 读 `/dev/sdf2`（1 次），尚未加规则（需改共享 SELinux 注册表，会波及他机型）。
- 工具本身的两处缺陷已修：连续日志上限 30MB→120MB 且停止后窗口改取缓冲区增量（上一轮 NFC/小爱因此零数据）；
  主题切片改为单趟 awk 分桶（原先 6 趟 grep 在 52MB 日志上跑不完，导致回传时 `SUMMARY`/`92_*` 还是旧的）。

本轮未动的事：不拿旧包证据判任何“补丁没落地”；`FACE_UNLOCK_SUPPORT_TEE` 不重新引入；其他机型的模块清单、
SELinux 注册表与共享默认值均未改变。下一轮取证必须用含 `disable_oplus_crash_loop.rc` 与新 product 产物的包。

### 远端测试者怎么采：一个文件、零参数、零填写

只需把 `tools/issue_trace.sh` 这一个文件发给对方，他做的事只有：

1. 把文件放到 `/sdcard/Download`，在 MT 管理器里放行 Root；
2. 长按该文件 →「打开方式 → Shell / 脚本执行」（**不需要带任何参数**）；
3. 看到「回传文件: /sdcard/Download/issue_trace_now.zip」（设备没 `zip` 时会是 `.tar.gz`，同样发回）后，把那个包发回。

已在真机跑通（Ace 6T DSU，2026-09-30 14:41）：全量默认路径跑完约 6-8 分钟，产出 43 个采集文件 +
SUMMARY + MANUAL，`tar.gz` 兜底正常（本机 `zip` 不可用）。两个踩过并已修掉的坑：
主 shell 直接 `kill` 自己的同组后台子进程会把采集自身打死（现改为 tick 靠标志位自退、
logcat 交给 `setsid`  helper 回收）；探针命令统一避开会永久阻塞的 `svc usb setFunctions` 与
本 ROM 未实现的 `cmd usb set-functions`，USB 切换只用 `setprop sys.usb.config`（并把 adb 一起列入避免断会话）。

**全程约 6-8 分钟（含静态基线与收尾）；中途不能关掉执行窗口**。脚本会逐个报「第 N/4 个场景」，
钱包只是第 3 个场景的最后一个动作，不是结束；提前关掉会让 SUMMARY.txt 和 zip 全部缺失（已实际踩过一次，
导致那份回传只能靠手动重算原始日志）。

**默认已是全量自动**：自动探针（开 NFC、USB 切“传输文件”、亮/息屏、拉起安全页与小爱会话、按音量键、
开钱包）+ 历史崩溃层（dropbox 崩溃/ANR/Watchdog/上次开机内核日志正文、tombstones 摘要与全文、
ANR traces、pstore/console-ramoops 关键字命中、ramdump 清单）+ 补丁落地哨兵 + 深度核查（65_deep_state.txt：
身份硬判据/人脸服务与计数/NFC 轮询掩码/MTP 前提/显示档位/音频抖动/底包环境）+ 整段连续 logcat 与周期 tick。
`MANUAL.txt` 可以不填。只有三件事脚本替不了：**正对手机解锁**、**把卡贴背部**、**开口喊小爱同学**
（没做也不报错）。脚本会在结束前把 zip 复制/确保落在下载目录。
维护者要只读跑时加 `--no-auto`（不触发探针、不改设备状态），再配 `--no-pause` 可最快出快照。

### Ace 6T 正常样本基线（给 Neo8 逐条比对用，2026-09-30 实测）

- 人脸可用侧：`IFace/default` 在 `service list`、`libstfaceunlockocl_uff.so` 在位、`ID(4) oemStrength/updatedStrength=4095 modality 8`、
  `vendor.oplus.face.bigmodel.support=true`、`sys.miface.auth.package=noback`；XML 为 `support_tee_face_unlock=true` + `region_dom=ALL`。
- 唤醒侧：`PortCpuKws=2`，`VT_AudioFlow: start` / `onEnoughData true` / `keyPhrase=小爱同学` 全链路通，
  `LOAD_PHRASE_MODEL=0`、`-22=0`、`HAL instance died=0`，audioserver pid 多次采样不变，`Hal write jitter ave=0.59ms`。
- 已知仍在本机的问题：`qguard`（缺 `libbase.so`）与 `syshealthmon-service`（`blocked syscall: lseek` → SIGSYS）
  严格 5 秒重拉、`updatable_crashing_process_name=qguard`，原因是 `disable_oplus_crash_loop` 尚未挂进 6T 组合。
- 仍未闭环：NFC 发现链健康（`NFA_RF_DISCOVERY_STARTED_EVT status=0`、`pollTech=0x2f`）但无卡被激活；
  MTP 切到了 `mtp` 而主机枚举未确认；双击亮屏与钱包 SE 未采到有效事件。

### 6T 长窗口复采的修正（2026-09-30 13:04，本机自主跑 `2026.09.30-3`）

上一轮“6T 上没采到米音/效果失败”的结论**错了**，原因是窗口太短 + 拿总次数当判据。用 4.6 分钟窗口重算：

- `AudioEffect: set(): could not create effect ec7178ec…/5b8e36a5…` = **56 次/4.6 分 ≈ 11-12 次/分（严格 5 秒一次）**
  → 这是**两机共有的 HyperOS 侧循环重试**，不是 Neo8 特有；Neo8 是 33 次，量级同（只是当时 6T 采不到）。
  因此从 `enable_hyperos_features` 撕 `ro.vendor.audio.*` 声明这个动作，对 6T 同样有价值，不再是“Neo8 专项”。
- `appname=` 裸词 53 次全是 PowerInsight/flutter 的 `appName='…'` 噪声；改用音频上下文严格模式后 **6T 也是 0**
  → `fuck_audio_appname` 在两台机器上都确认生效。
- `checkAndSetVolume invalid volume index` 6T 仅 2 次 vs Neo8 6650 次 → 音量曲线越界仍判为 **Neo8 底包侧显著更重**。
- 音频重启环：**修正为确认不存在**。之前“44 个不同 audioserver pid”是指标本身写错了——`91_ticks.txt` 里
  `TICK rss_kb ... audioserver=` 是内存不是 pid；按 `^TICK pid` 限窗后真实值为 **1（全程 2493）**。
  `HAL instance died`/`-22`/`LOAD_PHRASE_MODEL` 均为 0 → 6T 无重启环（CPU 前端在跑）。
- 窗口限窗后的循环节律（真机 SUMMARY）：`could not create effect` ≈ **12 次/分**、`qguard` 链接失败 ≈ **12-15 次/分**、
  ADSP 重试 0 次/分。未限窗的历史计数（如 1840 次）不能直接除以窗口时长。
- **新发现（工具独有、我手工漏掉的）**：12:23:57 `com.finshell.wallet/…TagcardActivity` **ANR**，
  binder 从 wallet → `com.android.nfc` 耗时 **5.027s** → 钱包/SE/NFC 交叉路径的真铁据，Neo8 钱包同理需关注；
  同时 `/proc/pressure/cpu some avg10=13.9` 佐证 CPU 压力。qguard/syshealthmon 崩溃环依旧（64/64 次，间隔混有 2s 与 5s）。

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
- 人脸解锁：已复现“能录入但解不开”；`FACE_UNLOCK_SUPPORT_TEE` 已按与 6T 同步的原则从入口移除（原因见上表与《2026-09-30 移植侧取证结论》）。
- NFC 开关已能开到 `on`（旧包回传），但发现层 `startRfDiscovery` 超时、零建链；需新包重贴卡并看 `NFC 发现层定量` 行。
- `MANUAL.txt` 测试者未填：主观观感、双击实测、人脸 2D/3D 文案、LHDC 列表、界面档位名仍空。
- `sec_touch`/`4100`/`4101` 节点在 `/sys` 深度 5 内未找到（探测深度不够，不是否定结论），下一版脚本需对
  `touchpanel` 所在 input 目录整目次探测。
- 1080x2354 为当前活动降档模式，DSU 下 HyperOS 可能默认抬到 1272x2772，刷新率/分辨率验证时要同时看
  `dumpsys display` 的 activeMode。

这些参数依赖实际运行设备，不能从小米原包推断。更换底包、面板、指纹模组、触控驱动或
SKU 后必须重新核对，不能直接照搬一加 15、一加 Ace 6/6T。`RealmeNeo8_port.sh` 会按固定
顺序组合 `common`、`features` 与本目录模块，并保证 SELinux 业务模块先于
`common/fix_vendor_avc` 安装。不要只根据本目录参数推断整套流程。
