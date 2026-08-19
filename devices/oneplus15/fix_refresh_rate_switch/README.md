# 一加 15 刷新率与分辨率切换

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product` | 修改当前原包机型的 `device_features` XML。 |
| `system_ext` | 修补 `Settings.apk` 的分辨率高度计算，并清理旧 oat 与 metadata。 |

`odm` 的显示配置只作为分辨率输入读取，不会被本模块修改。

## 模块说明

模块按 `init_port_env` 保存的原包设备代号修改 `product/etc/device_features/<device>.xml`：

- `smart_fps_value` 设为 165Hz。
- `fpsList` 设为 165、144、120、90、60Hz。
- 从底包 `odm/etc/sdm_display_resolution_extn.xml` 动态读取 `PanelResolution width` 与所有 `ScalingResolution w`，生成 `screen_resolution_supported`。

同时复用 `common/settings_apk_patcher.sh` 修正旧 `ScreenResolutionManager.calculateHeightFromWidth()`：优先从 `Display.getSupportedModes()` 取得目标宽度对应的真实高度；找不到时才按比例并以 `Math.round()` 回退。当前一加 15 的 1080 宽模式因此使用 2354 高度，不再截断为 2353。

机型 XML 与 `Settings.apk` 是两个独立子步骤；任一目标缺失时只跳过对应子步骤，另一项仍可继续。Settings 只替换目标 DEX，保留其他归档条目、APK Signing Block 与 `META-INF` 证书材料，并清理 oat。DEX 修改后内容完整性签名必然失效。

模块需要 Apktool、Java、Python 3、`zip`、`unzip` 与 Android SDK `zipalign`。

## 执行

```bash
bash port_main.sh devices/oneplus15/fix_refresh_rate_switch
```
