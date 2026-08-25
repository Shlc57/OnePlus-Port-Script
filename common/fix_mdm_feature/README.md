# 修复 mdm_feature 的 SVN/OTA 属性读取

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 合并 `/odm/etc/selinux/odm_property_contexts` 的三个精确 `exported_default_prop` 条目，并补齐该文件的 ODM contexts/fsconfig metadata。 |

## 模块说明

底包 `/odm/bin/hw/mdm_feature` 在 early-init 阶段读取：

```text
ro.build.version.svn.c
ro.build.version.svn
ro.build.version.ota
```

当前移植系统实际加载的 `odm_property_contexts` 缺少这三个条目，属性落到 `default_prop`，因此 Enforcing 下出现 `Access denied finding property`。原包的 `precompiled_property_contexts` 已给出精确的 `exported_default_prop` 标签；补丁只恢复这三个标签，不给 `mdm_feature` 增加 `default_prop` 宽权限，也不修改属性值。

该日志链主要影响 IMEISV/SVN、单双卡 feature map 等早期配置，不能单独证明 raw IMEI 或 SN 页面为空。当前设备实测 Settings 在 Enforcing 下仍可显示 IMEI，因此 raw IMEI/SN 若继续缺失，还需要依据对应 UI/Telephony 调用的 AVC 或返回值继续定位。

目标 `odm_property_contexts` 不存在时模块创建最小文件，并同步写入 ODM metadata；已存在时保留其它条目（例如 ADFR）后按路径幂等合并。

## 执行

```bash
bash port_main.sh common/fix_mdm_feature
```

一加 15 组合入口已在 `features/fix_ltpo` 之后调用本模块，确保 LTPO 先生成的 ODM property contexts 不会被覆盖。

## 验证边界

静态检查可以确认 active `odm_property_contexts` 的精确条目和 metadata；early-init 服务已经在当前启动完成，不能用热重载证明本次修复已被 `mdm_feature` 消费。需要下一次未污染 DSU 冷启动后检查：

```text
getprop -Z ro.build.version.svn.c
getprop -Z ro.build.version.svn
getprop -Z ro.build.version.ota
```

并确认 `mdm_feature` 不再输出对应拒绝。模块不执行重启。
