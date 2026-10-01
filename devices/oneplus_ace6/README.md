# 一加 Ace 6 模块与硬件参数

本目录保存由 `OPAce6_port.sh` 显式传给共享模块的一加 Ace 6 硬件参数，以及本机型专属补丁。完整执行方法见 [`README_ACE6.md`](../../README_ACE6.md)。

## 机型基本信息

| 项目 | 值 |
| --- | --- |
| 市场名 | 一加 Ace 6（OnePlus Ace 6） |
| 设备代号 / OEM | PLQ110 / OP6113 |
| 处理器 | 骁龙 8 至尊版，显示 Target `sun`（与一加 15 同平台） |
| 内核 | 6.6（SM8750）；Millet 核心桥用 DDK `android15-6.6` 编译的 `prebuilt/android15-6.6/millet_core.ko` 接入，本仓库已构建 |
| 屏幕 | 6.83″ 1.5K **165Hz 五档屏**（60/90/120/144/165，LTPS），面板原生 **1272x2800**（底包 sdm sun）；全亮度类 DC + 低亮度纯 DC，>1920Hz 高频 PWM |
| 物理 Display ID | `4630947185118785939`（dumpsys uniqueId 实测） |
| 电池 | 7800mAh（典型值） |
| 摄像头 | 后置 50MP+8MP，前置 16MP |
| 指纹 | 屏下超声波（3D） |
| NFC | 青藤 THN31（TMS 栈，非 NXP/ST） |
| 自动亮度表 | P7 面板亮度表（末端 1776 nit） |

## 专属模块

| 模块 | 改动分区 | 说明 |
| --- | --- | --- |
| 自动亮度接入（[`common/coloros_display`](../../common/coloros_display/README.md)，Profile `ace6`） | `odm`、`product`、`system`、`system_ext`、`vendor`、`my_product` | OP15 同款方案：`my_product/vendor/etc` 覆盖合并入 vendor，用 P_7 官方表生成含 `autoBrightness` 的 Display ID 配置，迁移 FusionLight 与 display RRO，禁用 `high_pwm_rgb`。需解包 `my_product`；manifest 已按 DNA_ace6 核实（FusionLight `fusionlight_Main_2_3.json`、display RRO `android_framework_res_overlay.display.product.24851.apk`，底包仅此两个文件；24851 为 Oplus display 工程 id，6T 底包同名，非机型 prjname）。 |
| 开机亮度（[`common/fix_boot_brightness`](../../common/fix_boot_brightness/README.md)，Profile `ace6`） | `product` | 安装启动亮度 Overlay 并移除 `MiuiFrameworkResOverlay.apk`。 |
| [`fix_refresh_rate_switch`](fix_refresh_rate_switch/README.md) | `product`、`system_ext` | DC/PWM 与刷新率切换修补。本机实测为 165Hz 五档屏（60/90/120/144/165、144/165Hz PWM），与 Ace 6T、一加 15 档位一致，互斥策略与 patcher 三处逐字节一致。 |
| [`fix_vendor_selinux_files`](fix_vendor_selinux_files/README.md) | `vendor` | 底包 vendor 缺 SELinux 版本标记时补齐（DNA_ace6 实测：`plat_sepolicy_vers.txt`=202404 **已存在**、`genfs_labels_version.txt` **缺失**；缺失方按已存在方同值补齐，两者皆无才用默认 202504），否则 `common/fix_vendor_avc` 会失败。 |

> THN31 NFC 桥接已升为共享模块 [`features/fix_nfc_tms_bridge`](../../features/fix_nfc_tms_bridge/README.md)（与真我 Neo8 共用），不再列在本机专属表。
> **现状：本机 NFC 仍未点亮（不得记为已修）。** 与 Neo8 不同，Ace 6 底包只有 TMS 一份 NFC HAL（无 ST/NXP 竞争者，
> 也无任何 init rc 声明 `INfc/default`，只有 odm VINTF 声明），所以 Neo8 那层“ST HAL 被节点别名救活后抢注”的问题
> 在本机不存在；它仍不通 ⇒ 存 TMS 路线的共同阻塞点。**2026-09-30 全树排查已定位该共同根因**：HAL 只认固定文件名，
> 读不到裸名 `libnfc-tms.conf`（底包只带 `_<project>` 后缀，本机 project id 为 **24851**；裸名原本由 realme 原厂
> system 侧 Oplus `NfcNci.apk` 用 `copyFile` 铺）⇒ 设备节点回退到不存在的 `/dev/thn31`，TMS 专有配置全部丢失。
> 现已由 [`features/fix_nfc_tms_bridge`](../../features/fix_nfc_tms_bridge/README.md) 第 8/9 步补上（`/dev/thn31` 别名 +
> `odm/etc` 裸名 + `post-fs-data` 铺入 `/data/vendor/nfc/`），**两台共用同一修复、仍待真机确认**。本机无 ST 干扰，
> 它是验证这一步最干净的样本：**下一步优先在 Ace 6 上采一份 `nfc` 场景回传**（带自动探针、贴卡一次）。

> 本机流程已对齐「Ace 6T + 真我 Neo8 的超集」：新增 ColorOS 钱包、Millet 核心桥、`disable_oplus_crash_loop`，并把 `fix_face_unlock` 移到 `fix_device_identity` 之后；同时保留 Ace 6 特有修复——青藤 THN31 走 TMS NFC 桥（不用 NXP `fix_nci_nfc`）、`fix_vendor_selinux_files`（底包缺 SELinux 版本文件）、小爱走 SM8750 的 ADSP 路线。

## 共享模块参数

| 配置 | 消费模块 | 用途 | 状态 |
| --- | --- | --- | --- |
| `config/display_odm.props`、`display_vendor.props` | `common/fix_boot_refresh_rate` | 其余显示与触控策略；刷新率数值属性由底包按 `PORT_DISPLAY_TARGET=sun` 自动生成。 | 初始值沿用一加 15 流程，待实机核对 |
| `config/nfc.props` | `features/fix_nfc_tms_bridge` | 写入 odm 的 Xiaomi NFC 兼容属性。 | 待实机核对 |
| `config/linear_haptic.props` + `LINEAR_HAPTIC_MOTOR_TYPE=linear` | `features/fix_linear_haptic` | `sys.haptic.*` 映射与开机马达类型。 | 档位沿用一加 15，待实机核对 |
| `config/fingerprint.props` | `features/fix_ultrasonic_fingerprint` | 超声波指纹参考坐标、区域、协议与延迟；`ultrasonic.fp.target=sun` 过滤底包多平台分辨率。 | 传感器中心为换算估算值，实机可校准后重跑 |
| `config/double_tap_wake.props` | `features/fix_oplus_double_tap_wake` | Oplus HBP 节点、TouchFeature 能力位与 WAKE keylayout 参数。 | 沿用一加 15 触控栈值，实机需校准 |
| `config/xiaoai_wakeup.props`（经 `XIAOAI_WAKEUP_PROPERTIES_FILE`） | `features/fix_xiaoai_wakeup` | `odm.prjname=24851`（底包 `ro.separate.soft` / `odm/etc/fingerprint.json`）；不写 `xiaoai_cpu_kws`，即 SM8750（Target sun）保留 ADSP 热唤醒路线；不覆盖 `support_record_type`、不改写 PAL `concurrent_capture`。入口已置 `XIAOAI_VOICETRIGGER_PATCH=true`，互联兜底与声学迁移仍执行。 | **未在本仓库真机验证**：ADSP 可用只依据一加 13 同平台的历史实测。真机拍到 `-22` / `set_custom_config failed 10` / 零检出时，在本文件放开 `xiaoai_cpu_kws=true` + `pal_concurrent_capture=true` 即整组切到 CPU 前端 |
| `config/init.usb.configfs.rc` | `common/fix_mtp` | Ace 6 底包 USB configfs rc（`mtp.gs0` 纯触发器形态），替换被小米原包覆盖的目标。 | 已从底包提取，与 Ace 6T 版本逐字节一致 |
| `PORT_TARGET_DISPLAY_ID` | `common/coloros_display`、`common/fix_boot_refresh_rate` | Android framework 主屏物理 Display ID。 | 实测 |
| `COLOROS_DISPLAY_PROFILE=ace6` | `common/coloros_display` | 显式锁定显示接入 Profile；未注入时按底包识别值自动匹配。 | 实测 |
| `BOOT_BRIGHTNESS_PROFILE=ace6` | `common/fix_boot_brightness` | 显式锁定机型 Profile；未注入时按底包识别值自动匹配。Overlay、校验文件都在模块 `profiles/ace6/` 内。 | 实测 |
| `config/wallet_identity.props`（经 `WALLET_IDENTITY_PROPERTIES_FILE`） | `features/fix_coloros_wallet` | ColorOS 钱包身份真值：`device=OP6113L1`、`model=PLQ110`、`cuptsm=ONEPLUS\|ESE\|01\|27`、`oplusrom=V16.1.0`、`.display=16.1`，均取自 DNA_ace6 底包（cuptsm 尾号 01\|27 不同于 Ace 6T 的 01\|02）。prebuilt 五件套为共享产物，缺失则整体跳过。 | DNA_ace6 底包实测 |
| `RUNTIME_DEVICE_CODE=OP6113L1` + `XIAOAI_VOICEASSIST_DEVICE_CODE=OP6113L1` | `common/fix_device_identity`、`common/fix_face_unlock`、`features/fix_xiaoai_wakeup` | 启用钱包后 odm.device→OP6113L1，`fix_device_identity` 把原包机型 XML 改名为 `OP6113L1.xml`；`fix_face_unlock` 与小爱白名单都跟这个运行时代号。 | 代号取自 DNA_ace6 底包 fingerprint.json；boot 后需复核运行时 Build.DEVICE |
| `KMI=android15-6.6` | `features/oplus_millet_core_bridge` | 底包 vendor_dlkm `.ko` vermagic 实测 `6.6.89-android15-8-o-…-4k`（android15-6.6 族），选择本仓库已编译的 6.6 KO。KO 只匹配内核 vermagic，与 Android 版本无关。 | KMI 已底包实测；加载待刷机验证 |
| （无参数文件） | `common/disable_oplus_crash_loop` | 停掉底包 qguard / syshealthmon-service 崩溃环；不处理同名 fidoca（底包 Oplus FIDO HAL 服务名恰为 fidoca、正常运行；Xiaomi `vendor.mfidoca` 由 `fix_mi_account` 的 `oneshot`+`disabled` 已止环，详见补丁 README）。只读预检，服务不存在则整体跳过（与真我 Neo8 / Ace 6T 同款）。 | 与 Neo8 / Ace 6T 对齐引入 |

这些参数依赖实际运行设备，不能从小米原包推断。更换底包、面板、指纹模组、触控驱动或 SKU 后必须重新核对，不能直接照搬一加 15、一加 Ace 6T 或其他机型。

`OPAce6_port.sh` 会按固定顺序组合 `common`、`features` 与本目录模块，并保证 SELinux 业务模块先于 `common/fix_vendor_avc` 安装。不要只根据本目录参数推断整套流程。
