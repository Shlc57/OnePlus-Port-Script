# 一加 15 自动亮度适配

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 注释两份 ODM 属性文件中的高 PWM RGB 传感器属性。 |
| `product` | 合并底包显示配置，生成目标 Display ID 配置，安装自动亮度曲线与启动亮度 Overlay，并补齐 metadata。 |

`vendor` 只提供 `etc/displayconfig` 与 fsconfig 来源，不会被本模块修改。

## 模块说明

模块禁用一加 15 的 `ro.vendor.oplus.sensor.high_pwm_rgb` 属性，把底包 `vendor/etc/displayconfig` 的缺失项补入原包 `product/etc/displayconfig`，并以 `PORT_TARGET_DISPLAY_ID` 指定的实机物理 Display ID 选择显示配置：若底包已有同名 `display_id_<ID>.xml` 则直接使用；否则要求所有候选 XML 通过相同的亮度结构契约，再按文件名字典序选取。候选契约不一致时安全失败，不按文件大小或其他易变身份信息猜测。复制时同步把 vendor fsconfig 前缀转换到 product，并为目标 ID 动态写入 product contexts/fsconfig。

亮度映射保留 Xiaomi `1..1060` 的逻辑 nit 上限，只根据真机 P3 表扩展物理高亮段：普通/HBM 分界为 1400 nit，HBM 末端为 1800 nit。当前预编译 `MiuiFrameworkResOverlay.apk` 的 `config_defaultLogicalCurve` 为 `0→2、30→40、600→70、5000→1060`，只校准环境光到逻辑 nit 的室内映射，不把物理 P3 nit 写入逻辑坐标。

模块还安装只覆盖 `config_screenBrightnessSettingDefaultFloat` 的 135 nit 启动亮度 Overlay。它要求保留现有 `AospFrameworkResOverlay.apk` 与 `MiuiFrameworkResOverlay.apk`，因为删除原厂亮度 Overlay 会连带破坏自动亮度曲线。

## 完整性与限制

写入曲线 Overlay 前会用 Android SDK `zipalign` 检查 4 字节边界。预编译 APK 未对齐时，模块先生成并复验临时对齐副本，避免 PackageManager 解析 `resources.arsc` 时导致 `system_server` 启动循环。两个模块内 Overlay 都会先验证 SHA-256。

曲线 Overlay 是预编译资源 APK，已移除原签名材料；只适用于已确认移植系统允许该 Overlay 重新生成并绕过原包完整性校验的环境。4 字节对齐后的产物已在一加 15 DSU 上确认能够正常完成开机。

模块需要 Python 3、`sha256sum` 与 Android SDK `zipalign`。

## 执行

```bash
PORT_TARGET_DISPLAY_ID=4630946903293830803 \
  bash port_main.sh devices/oneplus15/fix_auto_brightness
```

`PORT_TARGET_DISPLAY_ID` 必须是 uint64 范围内的正十进制 ID。完整一加 15 组合流程会提供当前默认值，也可以在调用 `OP15_port.sh` 时从外部覆盖。
