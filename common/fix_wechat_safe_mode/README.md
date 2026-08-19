# 修复微信安全模式

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 删除假的 Camera Extensions 实现及对应 contexts、fsconfig。 |

## 模块说明

模块移除 `odm/framework/androidx.camera.extensions.impl.fake.jar`，并同步清理该路径及子路径的 ODM metadata，用于修复这套假 Camera Extensions 实现触发的微信安全模式问题。

目标文件不存在时会安全跳过，metadata 清理保持幂等。

## 执行

```bash
bash port_main.sh common/fix_wechat_safe_mode
```
