# 自动识别底包刷新率并修复切换

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 从底包显示能力生成并合并 4 项刷新率属性。 |
| `product` | 修改原包设备的 `device_features` XML，写入底包可用刷新率与分辨率列表。 |
| `system_ext` | 修补 `Settings.apk` 的分辨率高度计算，并清理旧 oat 与 metadata。 |

## 底包输入

模块自动读取以下底包文件，不依赖设备专属的硬编码刷新率列表或刷新率属性配置：

- `vendor/build.prop`：读取 `ro.board.platform`。
- `vendor/bin/init.qti.display_boot.sh`：按平台分支读取 `vendor.display.target.version`。
- `vendor/etc/display/advanced_sf_offsets.xml`：读取对应 `Device` 的 `FpsOffsetMap`。
- `odm/etc/build.prop`：读取现有默认刷新率、低帧率和策略尾部，生成最终属性。
- `odm/etc/sdm_display_resolution_extn.xml`：读取面板和缩放分辨率；缺失时只跳过分辨率数组更新。

刷新率列表按降序生成，并只把 `>=60Hz` 的显示栈模式写入 `smart_fps_value` 与 `fpsList`。当前底包的 `canoe -> target.version 6` 会得到 `165、144、120、90、60Hz`。生成的属性包括：

- `ro.vendor.display.default_fps`
- `ro.vendor.display.fod_monitor_default_fps`
- `ro.vendor.display.dynamic_refresh_rate`
- `ro.vendor.mi_sf.new_dynamic_refresh_rate`

动态属性的低刷新率部分和冒号后的策略参数从底包原值保留；当前底包生成结果为 `165,144,120,90,60,30:100,60,5` 与 `165,60:5`。底包来源缺失或格式无效时，不使用硬编码回退。

其余显示与触控策略仍由目标机型组合入口分别通过 `DISPLAY_POLICY_ODM_PROPERTIES_FILE`、`DISPLAY_POLICY_VENDOR_PROPERTIES_FILE` 显式提供，并按模块白名单合并。一加 15 使用 `display_odm.props` 与 `display_vendor.props`；这两份文件不允许决定上述 4 个刷新率属性。

原包机型 XML 由 `PORT_SOURCE_DEVICE_FEATURE_FILE` 提供。Settings 子步骤与 XML 子步骤相互独立，目标缺失时只跳过对应步骤；APK DEX 修改会使原签名失效。

模块需要 Python 3。执行 Settings 子步骤时还需要 Java、Apktool、`zip`、`unzip` 和 Android SDK `zipalign`。同一平台分支若静态映射到多个不同的 `target.version`，模块会拒绝猜测并在修改工作树前失败。

## 执行

```bash
bash port_main.sh common/fix_boot_refresh_rate
```

一加 15 的 `OP15_port.sh` 已直接调用本模块。
