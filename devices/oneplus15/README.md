# 一加 15 模块与硬件参数

本目录只保存无法抽象为共享能力的一加 15 专属补丁，以及由一加 15 组合入口显式传给共享模块的硬件参数。完整执行方法见 [`README_OP15.md`](../../README_OP15.md)。

## 改动分区

本目录下的专属补丁直接改动 `odm`、`product` 和 `system_ext`；`vendor` 只作为自动亮度显示配置的来源读取。共享模块消费本目录参数时，实际目标分区以各自模块 README 为准。

## 专属模块

| 模块 | 改动分区 | 说明 |
| --- | --- | --- |
| [`fix_auto_brightness`](fix_auto_brightness/README.md) | `odm`、`product` | 适配一加 15 的传感器属性、显示配置、自动亮度曲线与启动亮度。 |
| [`fix_refresh_rate_switch`](fix_refresh_rate_switch/README.md) | `product`、`system_ext` | 配置 165/144/120/90/60Hz 与底包实际分辨率切换。 |

## 共享模块参数

| 配置 | 消费模块 | 用途 |
| --- | --- | --- |
| `config/refresh_odm.props`、`refresh_vendor.props` | `common/fix_boot_refresh_rate` | 显示、刷新率和触控属性。 |
| `config/nfc.props` | `common/fix_nfc` | Xiaomi NFC 上层兼容属性。 |
| `config/linear_haptic.props` | `common/fix_linear_haptic` | `sys.haptic.*` 映射。 |
| `config/fingerprint.props` | `features/fix_ultrasonic_fingerprint` | 超声波指纹参考坐标、区域、协议与延迟。 |
| `config/double_tap_wake.props` | `features/fix_oplus_double_tap_wake` | Oplus HBP 节点、TouchFeature 能力位和设备专属 WAKE keylayout 参数。 |

这些参数依赖实际运行设备，不能从小米原包推断。更换底包、面板、指纹模组、触控驱动或 SKU 后必须重新核对，不能直接照搬。

`OP15_port.sh` 会按固定顺序组合 `common`、`features` 与本目录模块，并保证 SELinux 业务模块先于 `common/fix_vendor_avc` 安装。不要只根据本目录的两个专属模块推断整套流程。
