# 写入原包设备标识

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 向 `odm/build.prop`、`odm/etc/build.prop` 写入原包身份与版本属性，并可覆盖机型显示名。 |
| `system` | 向 `system/system/build.prop` 同步品牌、厂商、型号与产品名。 |

## 输入与行为

基础身份从 `mi_odm/etc/build.prop` 动态读取。组合入口可以通过 `DEVICE_IDENTITY_PROP` 指定同目录下的 SKU 附加 `.prop` 文件；模块会把该文件中的全部有效属性合并到两份 ODM 目标，再用已识别的基础身份属性完成标准字段写入。

设置 `DEVICE_DISPLAY_NAME` 时，模块用该参数覆盖 `ro.product.odm.marketname`；参数只影响显示名，不改变原包设备代号、产品名、技术型号或认证字段。未设置参数时沿用 `mi_odm` 基础属性及可选附加 prop 中解析出的 `ro.product.odm.marketname`。

附加文件不存在时只警告并忽略，基础设备标识仍会继续写入。属性目标缺失时只跳过对应目标；格式无效、属性重复或符号链接不安全时会失败。模块使用 `init_port_env` 保存的原包身份快照，不会从已被前序补丁修改的 ODM 重新推断设备。

## 执行

```bash
DEVICE_IDENTITY_PROP=nezha_5.9.9.prop \
bash port_main.sh common/fix_device_identity

# 可选：显式覆盖设备显示名
DEVICE_DISPLAY_NAME='OnePlus 15' \
bash port_main.sh common/fix_device_identity
```
