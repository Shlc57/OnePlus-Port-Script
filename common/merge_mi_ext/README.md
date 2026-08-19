# 合并 mi_ext 到最终分区

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product` | 合并 `mi_ext/product` 内容及其 contexts、fsconfig、属性。 |
| `system_ext` | 合并 `mi_ext/system_ext` 内容及其 contexts、fsconfig。 |
| `system` | 合并 `mi_ext/system` 与 `mi_ext/etc`，写入兼容路径及 metadata。 |
| `mi_ext`（来源目录） | 全部目标写入成功后删除来源目录。 |

`mi_ext` 不是最终刷入时继续保留的同名分区。

## 模块说明

模块将 mi_ext 中的 product、system_ext、system 与 etc 内容映射到真实目标路径，同时迁移 contexts、fsconfig 和属性。它还会迁移 CustFeatureResolve 启用属性，并建立运行时 `/mi_ext/product -> /product` 兼容路径。

所有目标分区、来源 metadata 与路径转换会在复制前校验。只有文件和 metadata 全部成功合并后才删除 `mi_ext` 源目录；重复执行时，来源已不存在会安全跳过。

## 执行

```bash
bash port_main.sh common/merge_mi_ext
```
