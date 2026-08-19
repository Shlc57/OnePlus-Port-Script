# 禁用 ODM 外部属性导入

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 注释 `odm/build.prop` 与 `odm/etc/build.prop` 中的项目专属属性导入。 |

## 模块说明

模块禁用以下两类外部 `build.prop` 导入，避免最终 ODM 在运行时继续加载目标项目或 `my_manifest` 提供的额外属性：

- `/odm/etc/${ro.boot.prjname}/build.prop`
- `/mnt/vendor/my_manifest/build.prop`

目标文件或对应导入不存在时只警告并跳过；已注释的条目会安全跳过。模块只修改现有属性文件，不新增文件，也不修改 metadata。

## 执行

```bash
bash port_main.sh common/disable_odm_imports
```
