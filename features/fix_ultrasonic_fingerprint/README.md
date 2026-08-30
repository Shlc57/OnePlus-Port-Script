# 配置超声波屏下指纹

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 向 `odm/build.prop` 写入指纹能力、协议、坐标、尺寸、识别区域和按下延迟。 |

## 输入与计算

组合入口必须通过 `ULTRASONIC_FP_PROPERTIES_FILE` 提供目标设备实测 `.props` 文件。模块不包含机型默认值，也不从小米原包推断指纹硬件。参数包含参考分辨率、传感器中心、图标尺寸、识别区域尺寸、厂商协议与 fingerdown 延迟；模块会校验格式、重复键、数值范围和区域边界。

模块从底包 `odm/etc/sdm_display_resolution_extn.xml` 读取唯一 `PanelResolution`，分别按 X/Y 比例换算目标坐标，再写入以下属性族：

底包显示配置可能含多个 `Target`（如 Ace 6 同时含 anorak 异平台大屏与 sun 本机面板）。参数文件可提供可选键 `ultrasonic.fp.target` 指定本机 Target：设置后模块只收集匹配 `Target` 下的 `PanelResolution`，配置中不存在该 `Target` 时在修改工作树前失败；未设置时按全部面板收集，一加 15 流程行为不变。

```text
ro.hardware.fp.fod.*
persist.vendor.sys.fp.vendor
persist.vendor.sys.fp.fod.location.X_Y
persist.vendor.sys.fp.fod.size.width_height
persist.vendor.sys.fp.fod.us.target
persist.vendor.sys.fp.fod.delay.fingerdown.ms
```

一加 15 的参考参数集中在 `devices/oneplus15/config/fingerprint.props`：参考面板 `1272x2772`、中心 `636,2048`、图标 `195x195`、识别区 `220x242`、协议 `oplus`、延迟 `20ms`。在当前参考面板上得到图标位置 `539,1951` 与识别区域 `526,1927,746,2169`。

模块需要 Python 3。目标属性或显示配置缺失时只警告并跳过；参数文件缺失或无效时会失败。

模块同时登记一个只覆盖已确认指纹链路的 SELinux bundle：精确 `ro.hardware.fp.fod`、`ro.hardware.fp.fod.*`、`persist.vendor.sys.fp.vendor` 和 `persist.vendor.sys.fp.fod.*` 使用自有窄属性类型，并同步交付 vendor 与 precompiled property contexts。底包已有的 Oplus 指纹属性继续使用 `oppo_fingerprint_prop`；模块补回目标 `plat_pub_versioned.cil` 遗漏的 `oppo_fingerprint_prop_${API_VERSION}` 到裸类型映射，使 init 的通用属性权限以及 HAL、系统组件已有的版本化规则重新覆盖实际 property area。当前版本的 `MiuiSystemUI` 运行在 `platform_app` 域，因此该域也只获得上述窄 FOD 类型的读取权限，确保图标能够读取协议、位置和尺寸属性。`persist.vendor.rpmb.enable.state` 仍复用支付 HAL 已有的 `powerctl_prop`。不会采用 ZIP 中过宽的 `exported_default_prop` 或 rawdata 类型，也不会扩大成整个 `vendor.fingerprint.*`/`persist.vendor.fingerprint.*` 前缀。`common/fix_vendor_avc` 必须在本模块之后运行。

`platform_app` 读取规则已在一加 15 DSU 的 Enforcing 环境中通过 KernelSU 临时注入验证：重启 SystemUI 后锁屏指纹图标恢复。该结果证明当前运行时读取链路；永久 bundle 的冷启动加载仍以重新生成并启动新的 DSU 后确认为准。

## 执行

```bash
ULTRASONIC_FP_PROPERTIES_FILE=/path/to/fingerprint.props \
bash port_main.sh features/fix_ultrasonic_fingerprint common/fix_vendor_avc
```
