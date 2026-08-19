# 隔离小米 MTP 与 DownloadProvider 进程

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system` | 修改 `MtpService.apk`，并清理其旧 oat、profile、FS-Verity 文件及 metadata。 |

## 模块说明

模块精准修改 `system/system/priv-app/MtpService/MtpService.apk` 的 application 进程名，把与 `DownloadProvider` 共用的 `android.process.media` 改为 `android.process.mtp`。这可避免小米 DownloadProvider 启动期 `BootHelper` 在空闲状态调用 `XCrashlytics.killSelf()` 时杀掉同 PID 的 MTP 服务。

补丁只回写二进制 `AndroidManifest.xml`，保留其他归档条目、APK Signing Block 和 `META-INF` 证书材料。Manifest 改动后 v1/v2/v3 内容完整性签名必然失效，仅适用于已确认系统包允许回退加载并绕过完整性校验的移植环境。

需要 Java、Apktool、Python 3、`zip`、`unzip` 与 Android SDK `zipalign`。目标 APK 不存在时只警告并跳过。

## 执行

```bash
bash port_main.sh common/fix_mi_mtp_kill_self
```
