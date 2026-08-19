# 合并 Pangu system 内容

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product` | 删除 `product/pangu/system` 源树及对应 contexts、fsconfig 条目。 |
| `system` | 将源树合并到 `system/system`，并写入转换后的 contexts、fsconfig。 |

## 模块说明

模块把 `product/pangu/system` 合并到最终 system 文件树，同时将 metadata 路径从 `/product/pangu/system`、`product/pangu/system` 转换为 `/system/system`、`system/system`。来源和目标 contexts、fsconfig 会在复制前完整预检；成功后才删除 product 中的源目录与源 metadata。

源目录不存在时视为可能已经完成合并并安全跳过。

## 执行

```bash
bash port_main.sh common/fix_pangu
```
