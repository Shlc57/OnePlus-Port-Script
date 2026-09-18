# 关闭 HyperOS iorap 预读（iorapd 重启环）

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product` | 向 `product/etc/build.prop` 写入 `persist.sys.stability.PrereadEnable=false` 默认值。 |
| `odm` | 新增 `odm/etc/init/disable_hyperos_preread.rc`：属性被置 `true` 时改回 `false` 并 `stop iorapd`；同步该路径的 contexts（`vendor_configs_file`）与 fsconfig（`0 0 0644`）。 |

## 模块说明

`iorapd` 是原包 HyperOS 的服务（`system_ext/etc/init/init.launch_boost.rc` 中
`service iorapd /system_ext/bin/iorapd`，`class main` 且非 `oneshot`），其启停完全由
`persist.sys.stability.PrereadEnable` 的 `true`/`false` 触发器驱动。它依赖内核节点
`/dev/iorap_dev`，OnePlus 底包内核不提供该节点（真机日志
`Cannot open /dev/iorap_dev errno=2`），于是服务每次启动即失败、被 init 无限重启。

修复只走属性控制，不删除服务、不修改原包 rc：

- `product/etc/build.prop` 的默认值让干净 `data` 上该属性在加载期就是 `false`，
  原包的 `start iorapd` 触发器不成立。
- `persist.` 属性在 `/data/property` 中的值会覆盖 build.prop 默认值，因此补一条
  odm rc：一旦出现 `true`（持久值回填或用户在设置里开启应用预加载），立刻改回
  `false`，由原包 rc 自带的 `false` 触发器停服务。rc 里额外执行一次
  `stop iorapd`——它由 init 自身完成，不依赖属性写许可，作为 `setprop` 被策略
  拒绝时的兜底。
- 原包不再定义 `service iorapd` 或该 rc 不存在时，只警告并退化为纯属性禁用，
  不写入 `stop` 行；`product/etc/build.prop` 缺失时仅跳过属性子步骤。

`odm/etc/init` 的 rc 由 init 解析，早于任何 KSU 挂载，因此必须随镜像重打包生效，
不能用模块热替换。

## 验证边界

真机证据只有 Ace 6T DSU 上的重启环日志；停止后的效果需刷机或重装 DSU 复验
（`getprop persist.sys.stability.PrereadEnable` 应为 `false`，`getprop init.svc.iorapd`
应为空或 `stopped`，logcat 不再出现 `Cannot open /dev/iorap_dev`）。OnePlus 15 与 Ace 6
未实测，按同类内核前提推断；补丁本身幂等且只影响一个特性开关。

## 执行

```bash
bash port_main.sh common/disable_hyperos_preread
```
