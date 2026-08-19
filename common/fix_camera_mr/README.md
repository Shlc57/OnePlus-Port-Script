# 禁用不兼容的 CameraMR 输入

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product` | 修改 `product/etc/cust_features/device_features.xml` 与 `cust_features.xml`。 |

## 模块说明

模块把以下两项特性唯一设置为 `false`：

- `input_support_camera_mr`
- `settings_is_support_camera_mr_function`

这会避免非 Xiaomi 设备的活动识别传感器被误作 CameraMR 输入，并阻断由此引发的开机窗口焦点初始化崩溃。CameraMR 传感器语义不属于其他移植设备的目标硬件能力，因此该兼容处理位于 `common`。

两份 XML 必须配套修改；任一目标不存在时会警告并整体跳过。模块需要 Python 3，并在写回前后校验 XML 和目标特性的唯一性。

## 执行

```bash
bash port_main.sh common/fix_camera_mr
```
