# Oplus 指纹 HAL 协议适配

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system_ext` | 修改 `MiuiSystemUI.apk` 与 `miui-services.jar` 的目标 DEX，并清理旧 profile、FS-Verity 元数据和预编译产物。 |

## 模块说明

模块只对明确设置 `persist.vendor.sys.fp.vendor=oplus` 的系统生效，为 Oplus HAL 补齐 Xiaomi 锁屏 FOD 触摸协议：

- SystemUI 直接消费 `gxzw_touch` 窗口的原始 `ACTION_DOWN/UP/CANCEL`，使 `fod_animation_enabled=1` 时能在 HAL 认证结果到达前启动识别动画。
- 服务端在首次 `ACQUIRED_GOOD(0,0)` 合成 acquired 100 作为按下兜底。
- 认证成功、失败、HAL 错误或下一会话开始时合成 acquired 101，统一释放抬起状态。
- 认证成功撞上 `goingToSleep` 时，以 `android.policy:OPLUS_FOD` 主动唤醒，再保留原有轮询确认，避免成功结果被 SystemUI 吞掉。

非 Oplus 属性不受影响。`miui-services.jar` 与 `MiuiSystemUI.apk` 必须成对更新；任一目标缺失时会整体跳过，避免半套协议。

两部分已在一加 15 root DSU 热加载验证：亮屏锁屏按压命中原始触摸并启动动画，服务端稳定上报 acquired 100/101，息屏竞态可命中主动唤醒。息屏状态沿用系统自身的图标和解锁表现，不强制显示完整识别动画。

模块保留其他 JAR/APK 条目、APK Signing Block 与 `META-INF` 证书材料。DEX 修改后内容完整性与预编译产物必然失效，只适用于 Oplus 指纹 HAL 且已确认可从 DEX 回退加载的移植环境。需要 Java、Apktool、Python 3、`zip`、`unzip` 与 Android SDK `zipalign`。

## 执行

```bash
bash port_main.sh features/fix_oplus_fingerprint_protocol
```
