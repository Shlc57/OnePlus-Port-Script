# Xiaomi Phone SN 展示 fallback

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system_ext` | 在既有 `init.miui.ext.rc` 中登记一个启动完成后的只读属性 fallback。 |

## 语义边界

移植系统中的 Xiaomi `*#06#` Phone SN 字段消费 `ro.ril.oem.psno`，而目标底包没有可证明等价的 Xiaomi OEM-NV PSNO 生产者。本模块只在 `sys.boot_completed=1` 且 `ro.ril.oem.psno` 仍为空时，将目标设备 `ro.serialno` 复制进该展示字段。

这不是 Xiaomi modem PSNO 的恢复或语义证明；它不读取、不修改 modem NV，也不改变 IMEI、PCB SN（`ro.ril.oem.sno`）或 Factory ID（`ro.ril.factory_id`）。若未来存在晚于 `sys.boot_completed` 的真实 PSNO producer，该只读 fallback 会先占用属性，因此应先移除本模块并恢复真实 producer。

模块验证既有 `sno_prop` property context 后直接使用 init 内建 `setprop`，不新增 service、SELinux allow、file context 或 fsconfig。仅修改既有 RC 文件，因此不需要 metadata 路径变更。

## 执行

该模块可由组合流程在 `common/fix_mi_account` 后调用，也可以单独执行：

```bash
bash port_main.sh common/fix_xiaomi_psno
```

必须用包含该改动的 DSU 冷启动验证。验证时确认 `ro.gsid.image_running=1`、SELinux 仍为 Enforcing，并检查 `ro.serialno`、`ro.ril.oem.psno` 和 `*#06#` 的 Phone SN 字段；不要把静态写入或当前启动属性当作验证结果。
