# 一加 Ace 6T 自动亮度适配（面板 1272x2800，165Hz）

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 注释两份 ODM 属性文件中的高 PWM RGB 传感器属性（`ro.vendor.oplus.sensor.high_pwm_rgb`）。 |
| `product` | 合并底包显示配置，生成目标 Display ID 配置（含亮度曲线），安装启动亮度与环境光曲线 Overlay，并补齐 metadata。 |

`vendor` 只提供 `etc/displayconfig` 与 fsconfig 来源，不会被本模块修改。

## 模块说明

本模块采用与一加 15 `devices/oneplus15/fix_auto_brightness` 相同的 Overlay 方案与结构契约校验，
亮度表与边界参数来自 Ace 6T 实测（P7 面板）：

1. **Display ID 适配**：把底包 `vendor/etc/displayconfig` 的缺失项补入原包
   `product/etc/displayconfig`，以 `PORT_TARGET_DISPLAY_ID` 指定的实机物理 Display ID
   选择显示配置（由机型组合入口注入：`4630946700822127507`）：若底包已有同名
   `display_id_<ID>.xml` 则直接使用；否则要求所有候选 XML 通过相同的亮度结构契约，
   再按文件名字典序选取。候选契约不一致时安全失败，不按文件大小或其他易变身份信息猜测。
   复制时同步把 vendor fsconfig 前缀转换到 product，并为目标 ID 动态写入 product
   contexts/fsconfig 条目；`config/product_file_contexts`、`config/product_fsconfig`
   中的底包 Display ID 条目对应 Ace 6T 底包 `vendor/etc/displayconfig` 的既有文件清单。
2. **亮度曲线校准**：使用内置 P7 面板亮度表 `config/display_brightness_config_P_7.xml`
   （底包实测 4676 点，末端 1776 nit）生成目标 Display ID 的 `screenBrightnessMap`：
   - 启动默认亮度 `screenBrightnessDefault` 按 **135 nit** 写入；
   - 普通/HBM 分界按 **782 nit**（P7 表实测，backlight 4090/4675）计算 `transitionPoint`；
   - HBM 末端 **1776 nit** 为 P7 表实测峰值（注意不是旧文档预估的 1800，以实表为准）；
   - 手动补偿段把 Xiaomi 亮度控制器的逻辑 nit 上限（599.96~1060）压入 782 nit
     物理分界前的极窄区间，物理请求边界保持不变。
   边界数值可通过 `ACE6T_DEFAULT_NITS` / `ACE6T_STANDARD_MAX_NITS` / `ACE6T_HBM_MAX_NITS`
   覆盖；面板表缺失时降级为仅 Display ID 适配（Overlay 仍安装）。
3. **启动亮度 Overlay**：`prebuilt/product/overlay/Ace6TBootBrightnessOverlay.apk`
   （单资源 dimen `config_screenBrightnessSettingDefaultFloat` = 0.394047439，对应 135 nit
   的 backlight 比例，与生成的 `screenBrightnessDefault` 一致），仅覆盖启动默认亮度。
   APK 由 `gen_boot_overlay.py` 从上游一加 15 的预编译 boot overlay 替换启动亮度值生成
   （`resources.arsc` 偏移 576 唯一命中，4 字节对齐），因此包名沿用上游
   `android.oneplus15.bootbrightness.overlay`——RRO 按 `targetPackage` 与资源 ID 生效，
   包名不影响功能。`boot_brightness_overlay/` 为对照一加 15 的源码目录（dimen 已改为
   6T 值 0.394047439），供具备 Android SDK（aapt2 + android.jar）的环境重新编译；
   若改包名请同步修改该目录下的 `AndroidManifest.xml` 并重新生成 prebuilt APK。
4. **环境光曲线 Overlay**：`prebuilt/product/overlay/MiuiFrameworkResOverlay.apk`
   （复用上游一加 15 的预编译产物，包名 `android.miui.overlay`，资源与机型无关），
   覆盖 `config_defaultLogicalCurve` 为 `0→2、30→40、600→70、5000→1060` 逻辑 nit，
   保留 1060 逻辑上限，只校准环境光到逻辑 nit 的室内映射。

两个 Overlay 均做 SHA-256 校验；曲线 Overlay 安装前检查 4 字节对齐，未对齐时先生成并
复验临时对齐副本（避免 PackageManager 解析 `resources.arsc` 时触发 `system_server`
启动循环），与一加 15 流程一致。

## 与 common/fix_remove_stock_overlays 的互斥关系

本模块**要求保留原厂 `AospFrameworkResOverlay.apk` 与 `MiuiFrameworkResOverlay.apk`**，
删除原厂亮度 Overlay 会连带破坏自动亮度曲线（一加 15 README 同款约束）。
因此 `common/fix_remove_stock_overlays`（删 Overlay 修黑屏的替代路线）**不得与
本模块同时启用**，Ace 6T 组合流程 `OPAce6T_port.sh` 不应把它与本模块加入同一清单。

## 完整性与限制

- 需要 Python 3、`sha256sum` 与 Android SDK `zipalign`（经 `local.properties`/toolchain 解析）。
- 面板表解析与生成映射均带结构、范围与单调性校验，非法表会拒绝执行。
- 生成的 `screenBrightnessMap` 会覆盖底包 Display ID 配置中的原曲线；重复执行幂等
  （主显示配置经临时文件原子替换）。
- 面板表末端 nits 必须等于 `ACE6T_HBM_MAX_NITS`（默认 1776）、首行必须为 `0,0,0`，
  否则补丁拒绝执行；换底包/换批次后请按同格式更新内置表并同步边界参数。
- 曲线 Overlay 是预编译资源 APK（boot overlay 由
  `gen_boot_overlay.py` 从上游 APK 替换启动亮度值生成，已移除签名材料），
  只适用于已确认移植系统允许该 Overlay 重新生成并绕过原包完整性校验的环境。

## 执行

```bash
PORT_TARGET_DISPLAY_ID=4630946700822127507 bash port_main.sh devices/oneplus_ace6t/fix_auto_brightness
```

`PORT_TARGET_DISPLAY_ID` 必须是 uint64 范围内的正十进制 ID。完整 Ace 6T 组合流程会提供
该默认值，也可以在调用 `OPAce6T_port.sh` 时从外部覆盖。
