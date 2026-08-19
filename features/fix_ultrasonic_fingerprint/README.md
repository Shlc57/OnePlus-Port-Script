# 配置超声波屏下指纹

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 向 `odm/build.prop` 写入指纹能力、协议、坐标、尺寸、识别区域和按下延迟。 |

## 输入与计算

组合入口必须通过 `ULTRASONIC_FP_PROPERTIES_FILE` 提供目标设备实测 `.props` 文件。模块不包含机型默认值，也不从小米原包推断指纹硬件。参数包含参考分辨率、传感器中心、图标尺寸、识别区域尺寸、厂商协议与 fingerdown 延迟；模块会校验格式、重复键、数值范围和区域边界。

模块从底包 `odm/etc/sdm_display_resolution_extn.xml` 读取唯一 `PanelResolution`，分别按 X/Y 比例换算目标坐标，再写入以下属性族：

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

## 执行

```bash
ULTRASONIC_FP_PROPERTIES_FILE=/path/to/fingerprint.props \
bash port_main.sh features/fix_ultrasonic_fingerprint
```
