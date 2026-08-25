# DisplayFeature 兼容桥

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `vendor` | 从 `mi_vendor` 迁移 Xiaomi AIDL 服务、接口库与 metadata，并安装经过裁剪的服务 rc。 |
| `odm` | 安装轻量 `displayfeature.default.so`，补齐 contexts、fsconfig 与早期 SELinux contexts。 |

`mi_vendor` 只作为原包取材目录。

## 模块说明

模块保留 Xiaomi AIDL DisplayFeature 服务与接口库，用轻量 legacy HAL 桥替换完整 Xiaomi 显示 HAL，并把显示模式映射到底包 QDCM RenderIntent：

| Xiaomi 模式 | QDCM RenderIntent |
| --- | --- |
| 自适应 | `DefaultSRGB` |
| 鲜艳 | `EnhanceSRGB` |
| 原色 | `StandardSRGB` |

基础模式请求携带的 `value=1/2/3` 同时映射为暖色、中性、冷色 RGB/PCC，并与独立色温和护眼 PCC 合成后交给 SurfaceFlinger。纸张纹理及其他未映射特性会明确返回不支持。

mode 20 调光请求也由同一桥转发到底包 Oplus Panel Feature AIDL：`0x0e` 是 DC Alpha，`0xc7` 是 PWM Turbo。桥对每次请求显式先关闭另一条路径，再打开目标路径；不会轮询刷新率，也不在桥内复制 144/165Hz 互斥策略。当前 `0/1` 的面板最终语义仍需真实设备 getter/界面结果确认。

桥复用底包 `libqservice.so`、`libsdmclient.so`、`libsdm-disp-vndapis.so` 与 Oplus Panel Feature 服务。模块只验证底包已有的 Display Color、Panel Feature 服务和面板调色数据，不补齐缺失的显示栈。它会移除 rc 中不存在的 Xiaomi sysfs 与 `/vendor/bin/displayfeature` 引用，迁移清单文件的 contexts/fsconfig，并显式设置桥库 `0644` 权限。

版本化 `system_server`、servicemanager 回调 HAL、桥访问 SurfaceFlinger 以及桥访问 Oplus Panel Feature 的最小规则保存在本模块策略片段中；本模块不直接完成最终 vendor CIL 合并，必须在安装后执行 `common/fix_vendor_avc`。

本轮只完成主机静态分析、AIDL transaction 复核、交叉编译和策略片段契约检查；尚未执行 adb、DSU 挂载、服务重启、面板 getter/setter 或冷启动验证。不能把 DC/PWM 已生效写成设备结论。

本模块还登记 DisplayFeature/RGB 属性 contexts bundle，将目标设备实际拒绝的色温、RGB 球、色彩模式、护眼和面板信息属性精确标为底包已有的 `vendor_display_prop`。不引入宽泛 `default_prop` 或新的显示权限；由 `common/fix_vendor_avc` 在本模块之后统一写入 vendor 与 precompiled property contexts。

## 执行顺序

```bash
bash port_main.sh features/fix_displayfeature_bridge common/fix_vendor_avc
```
