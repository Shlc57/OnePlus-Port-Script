# 修复 Settings 触感能力判断

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system_ext` | 修补 `Settings.apk` 目标 DEX，并清理旧 oat 与 metadata。 |

## 模块说明

模块通过本目录的 `patch_apk.sh` 修改 Settings，使设置界面的触感能力判定返回支持。`Settings.apk` 不存在时只警告并跳过。

模块只将目标 DEX 写回原 APK，保留其他归档条目、APK Signing Block 与 `META-INF` 证书材料。共享补丁器直接比较本次处理前后的条目名称、顺序、压缩方式和非目标原始内容，不保存来源 APK 的 hash、大小或 CRC 快照，因此 OTA 改版不会仅因文件身份变化被拒绝。DEX 改动后 v1/v2/v3 内容完整性签名必然失效，只适用于目标设备确有可用触感 HAL 且系统扫描绕过完整性校验的 ROM。

需要 Apktool、Java、Python 3、`zip`、`unzip` 与 Android SDK `zipalign`。

## 执行

```bash
bash port_main.sh common/fix_settings_haptic
```
