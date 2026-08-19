# 启用 HyperOS 特性属性

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `product` | 向 `product/etc/build.prop` 写入 32 项模糊、材质、画质、游戏与声效属性。 |
| `vendor` | 向 `vendor/build.prop` 写入 `persist.vendor.XDRVersion=2.0`。 |

模块不修改 `system` 或 `system_ext`。

## 属性清单

模块将原教程第四部分中粘连的属性还原为独立条目。重复执行会更新同名属性并移除目标文件中的重复定义；任一目标不存在时只警告并独立跳过，另一分区仍可继续。

| 分类 | 目标文件 | 属性及目标值 |
| --- | --- | --- |
| 全局模糊 | `product/etc/build.prop` | `ro.config.low_ram.threshold_gb=`<br>`ro.config.low_ram.middle.threshold_gb=`<br>`ro.miui.backdrop_sampling_enabled=true`<br>`ro.config.low_ram.support_miuilite_plus=false`<br>`persist.sys.background_blur_supported=true` |
| 高级材质与转场 | `product/etc/build.prop` | `persist.sys.background_blur_status_default=false`<br>`persist.sys.background_blur_mode=0`<br>`ro.surface_flinger.supports_background_blur=1`<br>`ro.launcher.blur.appLaunch=1`<br>`ro.sf.blurs_are_expensive=0`<br>`persist.sys.add_blurnoise_supported=true`<br>`persist.sys.hyper_transition=true`<br>`persist.sys.hyper_transition_v=2`<br>`persist.sys.element_transition_supported=true`<br>`ro.miui.shell_anim_enable_fcb=true` |
| 画质增强 | `product/etc/build.prop` | `debug.config.media.video.frc.support=true`<br>`debug.config.media.video.ais.support=true`<br>`debug.config.media.video.aie.support=true`<br>`persist.sys.support_ultra_hdr=true` |
| 相册 Ultra HDR | `vendor/build.prop` | `persist.vendor.XDRVersion=2.0` |
| 游戏视频与性能 | `product/etc/build.prop` | `debug.game.video.support=true`<br>`debug.game.video.speed=true`<br>`debug.performance.tuning=1`<br>`video.accelerate.hw=1` |
| 空间音频与声效 | `product/etc/build.prop` | `ro.vendor.audio.surround.headphone.only=false`<br>`ro.vendor.audio.videobox.switch=true`<br>`ro.vendor.audio.feature.spatial=7`<br>`ro.vendor.audio.game.effect=true`<br>`ro.vendor.audio.sfx.earadj=true`<br>`ro.vendor.audio.sfx.scenario=true`<br>`ro.vendor.audio.sfx.harmankardon=true`<br>`ro.vendor.audio.surround.support=true`<br>`ro.vendor.audio.scenario.support=true` |

原教程没有提供 `ro.config.low_ram.threshold_gb` 与 `ro.config.low_ram.middle.threshold_gb` 的数值，因此模块保留为空值，不猜测设备阈值。

## 限制与验证

这些属性主要用于能力声明和功能入口判断。HyperOS 版本、SoC、显示栈或音频 HAL 不支持时，对应功能可能不生效；画质算法和空间音频不能只靠属性补齐底层实现。

`persist.vendor.XDRVersion=2.0` 只解除小米相册的私有 `isXdrSupport` 门控，不会创建 HDR 显示能力。应先确认第三方应用能够正常显示 HDR。一加 15 已通过临时 `setprop` 实机验证相册恢复 Ultra HDR。

## 执行

```bash
bash port_main.sh features/enable_hyperos_features
```
