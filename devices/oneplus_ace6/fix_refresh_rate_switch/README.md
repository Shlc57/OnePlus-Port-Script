# 一加 Ace 6 DC/PWM 与超高刷新率切换

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product`、`system_ext` | 启用 `dc_backlight_fps_incompatible`，修补 `MISettings.apk` 和 `Settings.apk`，并清理对应 oat 与 metadata。 |

刷新率属性、`fpsList` 和分辨率列表由 `common/fix_boot_refresh_rate` 从底包显示栈生成；本模块不重复维护刷新率数值。

## 模块说明

本模块与 `devices/oneplus15/fix_refresh_rate_switch` 采用同一套互斥策略与 Smali 锚点：
Ace 6 与一加 15 同为 165Hz 五档屏（60/90/120/144/165），DC/PWM 档位策略一致；
修补目标（原包机型 XML、MISettings、Settings）均在小米原包侧，与 OPPO 底包机型无关。
patcher 使用本目录副本（`patch_misettings_dc_refresh.sh`、`patch_settings_dc_refresh.sh`），
便于按 Ace 6 原包版本微调锚点。

## 互斥策略

- 关闭 Pro 时不再按 `mimotion_pwm_enable` 过滤刷新率列表，60/90/120/144/165Hz 全部保留；底层面板按已验证的刷新率策略使用 60–120Hz DC、144/165Hz PWM。
- 开启 Pro 时仍写入 `Settings.Secure.mimotion_pwm_enable == 2`，由原有 Settings `updatePwmValueToDF` 通过 mode 20 请求全局 PWM；列表和刷新率写入不再被 Pro 门禁改写。
- `dc_backlight_fps_incompatible=true` 只保留原有 144Hz 互斥链路：选择 144/165Hz 时退出 DC；在高刷状态开启独立 DC 调光时，既有确认流程回退到 120Hz，避免显式 DC 请求与高刷冲突。
- `wa/a.m(Context,int)`、`MiuiDisplaySettings.updatePwmValueToDF` 和 Settings AppFunction 不再因 Pro 关闭把 `>=144Hz` 请求改成 120Hz。

`mimotion_pwm_enable` 的值约定来自原有 Xiaomi Settings 链路：`2` 为 Pro/PWM，`1` 为 DC。

## APK 处理边界

脚本只替换 `MISettings.apk` 的 `classes.dex` 和 `Settings.apk` 的 `classes2.dex`，分别校验 APK 条目、非目标条目内容、Signing Block、zipalign 和 ZIP 完整性；Settings DEX 同时覆盖 `MiuiDisplaySettings.updatePwmValueToDF` 与 `MiuiAppFunctionDisplayUtils` 的刷新率列表、写入和互斥阈值。脚本可从旧版“按 Pro 过滤/回退”状态迁移到当前策略，并保持幂等。脚本还会删除旧 `product/priv-app/MISettings/oat`、`system_ext/priv-app/Settings/oat` 及对应分区 contexts/fsconfig 前缀。DEX 修改会使原 APK 内容签名失效，因此只适用于移植系统中已确认绕过该完整性校验的场景。

机型 XML、MISettings APK 或 Settings APK 任一目标缺失时只跳过对应子步骤；目标存在但类型错误、Smali 结构不匹配或 metadata 缺失会失败，避免生成半正确补丁。脚本同时校验 `NewRefreshRateFragment`、AntiFlicker 冲突链路、`wa/a.m` 公共写入点、`MiuiDisplaySettings.updatePwmValueToDF`、以及 Settings AppFunction 刷新率列表/写入链路的迁移状态。

## 执行

```bash
bash port_main.sh devices/oneplus_ace6/fix_refresh_rate_switch
```

需要 Python 3、Java、Apktool、`zip`、`unzip` 和 Android SDK `zipalign`（经 `local.properties`/toolchain 解析）。当前只完成静态/临时 APK 验证，未宣称真实设备生效。
