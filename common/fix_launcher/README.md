# 修复系统桌面启动配置

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 更新 `odm/build.prop` 与 `odm/etc/build.prop`。 |

## 模块说明

模块确保两份可用的 ODM 属性文件包含以下配置：

```properties
ro.miui.region=cn
ro.miui.product.home=com.miui.home
ro.apex.updatable=true
```

目标属性文件不存在时只警告并跳过；模块不新增属性文件，也不修改 metadata。

## 执行

```bash
bash port_main.sh common/fix_launcher
```
