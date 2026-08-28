# 修复人脸解锁与录入流程

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product` | 修改原包机型 `device_features` XML 中的人脸区域与 TEE 能力。 |
| `system_ext` | 修补 `Settings.apk` 的录入回调，并清理不匹配的 oat 与 metadata。 |
| `vendor` | 从 `mi_vendor` 迁移标准人脸硬件特性声明及其 contexts、fsconfig。 |

`mi_vendor` 只是只读来源目录，不是最终改动分区。

## 模块说明

模块按移植前识别的原包代号修改 `product/etc/device_features/<原包代号>.xml`：当 `support_face_unlock_region_dom` 不包含 `ALL` 时，将其中所有 `item` 设为 `ALL`；当 `support_tee_face_unlock` 不为 `true` 时将其设为 `true`。

从 `mi_vendor` 迁移 `android.hardware.biometrics.face.xml` 到最终 `vendor` 后，Settings 会走标准 `FaceManager`。模块会在有效 Surface 上正式开始录入时先进入小米原有 acquired 19 步骤，使相机预览就绪后及时结束加载提示；随后把 `remaining>0` 的标准进度映射到同一路径，并调整五段圆环节奏。只有 `remaining=0` 才进入成功流程；如果底层只上报最终回调，也会跳过没有结束监听器的第 0 个圆环，避免模板已保存但页面停住。

人脸特性 XML 或 `Settings.apk` 缺失时，这两个必须配套的文件子步骤会一起跳过，但 vendor 硬件特性声明迁移仍继续。模块需要 Apktool、Java、Python 3、`zip`、`unzip` 与 Android SDK `zipalign`。

Settings 只替换目标 DEX，保留其他归档条目、APK Signing Block 与 `META-INF` 证书材料，并清理来源 oat。共享补丁器直接比较本次处理前后的条目名称、顺序、压缩方式和非目标原始内容，不保存来源 APK 的 hash、大小或 CRC 快照，因此 OTA 改版不会仅因文件身份变化被拒绝。为避免大 APK 重建时触发 `/tmp` 用户配额，临时工作目录默认位于 `Settings.apk` 所在目录；可通过 `SETTINGS_APK_PATCH_TMPDIR` 显式指定其他可写目录。DEX 改动后 v1/v2/v3 内容完整性签名必然失效，只适用于已确认系统扫描允许回退加载且底包提供标准 Face HAL 的移植环境。

无需安装 `PearlBiometric.apk`：已在 nezha DSU 上移除用户 0 的 `com.miui.face`、确认进程与 `miui.face.FaceService` 均不存在后，实测录入、成功页退出和人脸解锁正常。

## 执行

```bash
bash port_main.sh common/fix_face_unlock
```
