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

桥复用底包 `libqservice.so`、`libsdmclient.so`、`libsdm-disp-vndapis.so` 与 QTI Display Color SELinux 域。模块只验证底包已有的 Display Color 能力，不补齐缺失的显示栈或面板调色数据。它会移除 rc 中不存在的 Xiaomi sysfs 与 `/vendor/bin/displayfeature` 引用，迁移清单文件的 contexts/fsconfig，并显式设置桥库 `0644` 权限。

版本化 `system_server`、servicemanager 回调 HAL 及桥访问 SurfaceFlinger 的规则保存在本模块策略片段中；本模块不直接完成最终 vendor CIL 合并，必须在安装后执行 `common/fix_vendor_avc`。

桥库已在一加 15 DSU 上通过 tmpfs 热替换验证三档 RGB/PCC 与 RenderIntent 切换；上层权限链已用 KSU 临时规则在 Enforcing 下验证，固化 CIL 仍需冷启动确认。

本模块还登记 DisplayFeature/RGB 属性 contexts bundle，将目标设备实际拒绝的色温、RGB 球、色彩模式、护眼和面板信息属性精确标为底包已有的 `vendor_display_prop`。不引入宽泛 `default_prop` 或新的显示权限；由 `common/fix_vendor_avc` 在本模块之后统一写入 vendor 与 precompiled property contexts。

## 执行顺序

```bash
bash port_main.sh features/fix_displayfeature_bridge common/fix_vendor_avc
```
