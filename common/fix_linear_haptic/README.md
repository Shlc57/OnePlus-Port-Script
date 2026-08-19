# 适配目标设备线性马达触感

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 合并 `sys.haptic.*` 属性到 `odm/etc/build.prop`，并修改 `odm/etc/init/vibrator-default.rc`。 |

## 输入与行为

- `LINEAR_HAPTIC_PROPERTIES_FILE`：目标设备的 `sys.haptic.*` 映射。
- `LINEAR_HAPTIC_MOTOR_TYPE`：开机完成后设置的马达类型。

模块不再从小米原包提取马达能力或效果编号。它会移除目标属性文件中静态的 `sys.haptic.motor` 与 `sys.haptic.version`，并在 `sys.boot_completed=1` 触发器下唯一设置配置的马达类型。一加 15 使用 `devices/oneplus15/config/linear_haptic.props` 和 `LINEAR_HAPTIC_MOTOR_TYPE=linear`。

未提供配置或目标文件缺失时只警告并跳过。底包触感 HAL、效果资源和实际震感仍须在目标设备验证。

## 执行

```bash
LINEAR_HAPTIC_PROPERTIES_FILE=/path/to/linear_haptic.props \
LINEAR_HAPTIC_MOTOR_TYPE=linear \
bash port_main.sh common/fix_linear_haptic
```
