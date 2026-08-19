# 修复 Oplus 基带与 Xiaomi OEM Hook 不兼容

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system` | 修改 `TeleService.apk` 的目标 DEX，并清理其 oat 与 metadata。 |

## 模块说明

模块保留小米 `qcrilmsgtunnel` 短信接收链路，同时精准修补 `TeleService.apk`：

- 跳过 `XtsApp` 不兼容的 Oplus modem 版本查询。
- 固定报告 XTS 不受支持。
- 短路 `MiRilHook.onHookNotifyScreenStatusSync` 发送的小米 `0x802AA/0x1B` 屏幕状态 OEM 命令，避免电话线程每次亮灭屏阻塞约 5 秒及 `QcrilOemhookMsgTunnel` 长时间持有 wakelock。

模块只替换目标 DEX，保留其他 APK 条目、Signing Block 与 `META-INF` 证书材料。DEX 改动后内容完整性签名必然失效，只适用于确实存在该 Oplus modem/Xiaomi OEM Hook 冲突且已确认系统扫描允许该产物的环境。

需要 Java、Apktool、Python 3、`zip`、`unzip` 与 Android SDK `zipalign`。`TeleService.apk` 不存在时只警告并跳过。

## 执行

```bash
bash port_main.sh common/fix_modem_xts
```
