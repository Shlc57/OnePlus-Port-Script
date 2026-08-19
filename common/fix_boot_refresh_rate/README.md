# 修复开机卡顿与锁 60Hz

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 将白名单内的显示、刷新率与触控属性合并到 `odm/etc/build.prop`。 |
| `vendor` | 将白名单内的显示属性合并到 `vendor/build.prop`。 |

## 输入

- `BOOT_REFRESH_RATE_ODM_PROPERTIES_FILE`：目标设备 ODM 属性配置。
- `BOOT_REFRESH_RATE_VENDOR_PROPERTIES_FILE`：目标设备 vendor 属性配置。
- 模块内的 `config/odm_props.list` 与 `config/vendor_props.list`：允许写入的属性白名单。

模块不再从小米原包 `mi_odm` 或 `mi_vendor` 推断面板、触控和刷新率能力。一加 15 的配置位于 `devices/oneplus15/config/refresh_odm.props` 与 `refresh_vendor.props`，由 `OP15_port.sh` 显式传入。

配置文件、目标文件或单项属性缺失时只警告并跳过对应子步骤。模块保留底包音频链和完整 ODM 文件树；LTPO 能力声明由 `features/fix_ltpo` 单独处理。

## 执行

```bash
BOOT_REFRESH_RATE_ODM_PROPERTIES_FILE=/path/to/refresh_odm.props \
BOOT_REFRESH_RATE_VENDOR_PROPERTIES_FILE=/path/to/refresh_vendor.props \
bash port_main.sh common/fix_boot_refresh_rate
```
