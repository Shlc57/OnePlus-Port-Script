# 一加 Ace 6 模块与硬件参数

本目录保存由 `OPAce6_port.sh` 显式传给共享模块的一加 Ace 6 硬件参数，以及本机型专属补丁。完整执行方法见 [`README_ACE6.md`](../../README_ACE6.md)。

## 机型基本信息

| 项目 | 值 |
| --- | --- |
| 市场名 | 一加 Ace 6（OnePlus Ace 6） |
| 设备代号 / OEM | PLQ110 / OP6113 |
| 处理器 | 骁龙 8 至尊版，显示 Target `sun`（与一加 15 同平台） |
| 内核 | 6.6（Millet 核心桥暂不可用，仓库预编译 KO 仅 `android16-6.12`） |
| 屏幕 | 6.83″ 1.5K LTPS **120Hz**，面板实测 **1270x2800**；全亮度类 DC + 低亮度纯 DC，>1920Hz 高频 PWM（档位待实机核对） |
| 物理 Display ID | `4630947185118785939`（dumpsys uniqueId 实测） |
| 电池 | 7800mAh（典型值） |
| 摄像头 | 后置 50MP+8MP，前置 16MP |
| 指纹 | 屏下超声波（3D） |
| NFC | 青藤 THN31（TMS 栈，非 NXP/ST） |
| 自动亮度表 | P7 面板亮度表（末端 1776 nit） |

## 专属模块

| 模块 | 改动分区 | 说明 |
| --- | --- | --- |
| 自动亮度接入（[`common/coloros_display`](../../common/coloros_display/README.md)，Profile `ace6`） | `odm`、`product`、`system`、`system_ext`、`vendor`、`my_product` | OP15 同款方案：`my_product/vendor/etc` 覆盖合并入 vendor，用 P_7 官方表生成含 `autoBrightness` 的 Display ID 配置，迁移 FusionLight 与 display RRO，禁用 `high_pwm_rgb`。需解包 `my_product`；manifest 暂按 Ace 6T 模板，待实机核实。 |
| 开机亮度（[`common/fix_boot_brightness`](../../common/fix_boot_brightness/README.md)，Profile `ace6`） | `product` | 安装启动亮度 Overlay 并移除 `MiuiFrameworkResOverlay.apk`。 |
| [`fix_refresh_rate_switch`](fix_refresh_rate_switch/README.md) | `product`、`system_ext` | DC/PWM 与刷新率切换修补。注意：其互斥策略沿用一加 15 的 165Hz 五档屏假设（60/90/120/144/165、144/165Hz PWM），与本机 120Hz LTPS 面板不符，需按实机档位重审。 |
| [`fix_nfc_tms_bridge`](fix_nfc_tms_bridge/README.md) | `odm`、`system`、`vendor` | 青藤 THN31 TMS 栈桥接：保留底包 NFC 栈，注入 `/dev/st21nfc` 别名，登记最小 SELinux bundle。替代 NXP 专用的 `features/fix_nci_nfc`。 |
| [`fix_vendor_selinux_files`](fix_vendor_selinux_files/README.md) | `vendor` | 补齐底包缺失的 `plat_sepolicy_vers.txt` 与 `genfs_labels_version.txt`（实测 `202504`），否则 `common/fix_vendor_avc` 会失败。 |

## 共享模块参数

| 配置 | 消费模块 | 用途 | 状态 |
| --- | --- | --- | --- |
| `config/display_odm.props`、`display_vendor.props` | `common/fix_boot_refresh_rate` | 其余显示与触控策略；刷新率数值属性由底包按 `PORT_DISPLAY_TARGET=sun` 自动生成。 | 初始值沿用一加 15 流程，待实机核对 |
| `config/nfc.props` | `devices/oneplus_ace6/fix_nfc_tms_bridge` | 写入 odm 的 Xiaomi NFC 兼容属性。 | 待实机核对 |
| `config/linear_haptic.props` + `LINEAR_HAPTIC_MOTOR_TYPE=linear` | `features/fix_linear_haptic` | `sys.haptic.*` 映射与开机马达类型。 | 档位沿用一加 15，待实机核对 |
| `config/fingerprint.props` | `features/fix_ultrasonic_fingerprint` | 超声波指纹参考坐标、区域、协议与延迟；`ultrasonic.fp.target=sun` 过滤底包多平台分辨率。 | 传感器中心为换算估算值，实机可校准后重跑 |
| `config/double_tap_wake.props` | `features/fix_oplus_double_tap_wake` | Oplus HBP 节点、TouchFeature 能力位与 WAKE keylayout 参数。 | 沿用一加 15 触控栈值，实机需校准 |
| `config/init.usb.configfs.rc` | `common/fix_mtp` | Ace 6 底包 USB configfs rc（`mtp.gs0` 纯触发器形态），替换被小米原包覆盖的目标。 | 已从底包提取，与 Ace 6T 版本逐字节一致 |
| `PORT_TARGET_DISPLAY_ID` | `common/coloros_display`、`common/fix_boot_refresh_rate` | Android framework 主屏物理 Display ID。 | 实测 |
| `COLOROS_DISPLAY_PROFILE=ace6` | `common/coloros_display` | 显式锁定显示接入 Profile；未注入时按底包识别值自动匹配。 | 实测 |
| `BOOT_BRIGHTNESS_PROFILE=ace6` | `common/fix_boot_brightness` | 显式锁定机型 Profile；未注入时按底包识别值自动匹配。Overlay、校验文件都在模块 `profiles/ace6/` 内。 | 实测 |

这些参数依赖实际运行设备，不能从小米原包推断。更换底包、面板、指纹模组、触控驱动或 SKU 后必须重新核对，不能直接照搬一加 15、一加 Ace 6T 或其他机型。

`OPAce6_port.sh` 会按固定顺序组合 `common`、`features` 与本目录模块，并保证 SELinux 业务模块先于 `common/fix_vendor_avc` 安装。不要只根据本目录参数推断整套流程。
