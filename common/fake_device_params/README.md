# Settings 设备参数伪装

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `system` | 新增缓存模板、运行脚本与 init rc，修改平台 file contexts、平台 CIL、policy hash 及 system metadata。 |
| `system_ext`（条件性） | 仅当 `userdebug_plat_sepolicy.cil` 已存在时，同步写入相同的专用域规则。 |

模块不会修改 `odm` 或 `vendor`。开机后的专用服务会更新 user 0 的 `/data/user_de/0/com.android.settings` 缓存，但补丁执行阶段不修改解包的 data 分区。

## 模块说明

模块只生成 Settings 原生读取的 `basic_info_key` 与 `camera_info_key` 两个缓存值。缓存语言写入 `device_params_last_lang`，更新时间固定到 2100 年，使当前语言下不再触发 8 小时云端刷新。它不修改 `Build.MODEL`、`ro.product.*` 或其他 prop，也不替换 `HTMLViewer.apk`。

默认参数通过 `DEVICE_PARAMS_SPOOF_JSON` 传入。`basic` 是 `devInfoNew` 的完整响应对象，`camera` 是 `allparamInfo` 的完整响应对象；未识别的扩展字段会保留：

```bash
DEVICE_PARAMS_SPOOF_JSON='{
  "language": "zhCN",
  "basic": {
    "Mishop": {
      "RightValue": "",
      "ShowRedDot": "false",
      "Url": ""
    },
    "BasicInfoToggle": 1,
    "BasicItems": [
      {"Title": "处理器", "Summary": "第一代骁龙®8+移动平台", "Index": 0},
      {"Title": "电池容量", "Summary": "4800mAh(典型值)", "Index": 1},
      {"Title": "后置摄像头", "Summary": "50MP+8MP+2MP", "Index": 2},
      {"Title": "屏幕尺寸", "Summary": "6.7″", "Index": 3},
      {"Title": "分辨率", "Summary": "2412×1080", "Index": 4},
      {"Title": "安全芯片", "Summary": "独立安全芯片", "Index": 7}
    ]
  },
  "camera": {
    "status": true,
    "data": {
      "BasicInfoToggle": 1,
      "camera": {
        "front_camera": "16MP",
        "rear_camera": "50MP+8MP+2MP"
      }
    }
  }
}' bash port_main.sh common/fake_device_params
```

`language` 必须与目标系统当前 `Locale.getLanguage()+Locale.getCountry()` 一致，例如简体中文为 `zhCN`、美式英语为 `enUS`。如需英文模板，可额外设置 `DEVICE_PARAMS_SPOOF_JSON_ENUS`，且其中的 `language` 必须为 `enUS`；运行时在 `persist.sys.locale=en-US` 时选用英文模板，其他语言回退到默认模板。

`BasicItems[].Index` 只允许 `0`、`1`、`2`、`3`、`4`、`7` 且不能重复，分别对应处理器、电池、相机、屏幕尺寸、分辨率和安全芯片。启用 `BasicInfoToggle=1` 时，模块会自动追加空的索引 5 占位项，让 Settings 本地检测运行内存。型号索引 6 仍由 Settings 本地生成，不能由接口缓存覆盖。

## 生成文件与策略

模块生成并补齐 system contexts、fsconfig：

```text
system/system/etc/device_params/device_params_pref.xml
system/system/etc/device_params/device_params_pref.enUS.xml（设置英文参数时）
system/system/etc/device_params/fake_device_params.sh
system/system/etc/init/fake_device_params.rc
```

脚本权限为 `0755`，其余生成文件为 `0644`。模块以固定边界标记管理 `fake_device_params` 专用域，并动态定位限制 native domain 写 `system_app_data_file` 的属性，只把该域加入所需例外，不依赖易变的 `base_typeattr_*` 编号。规则写入 `system/system/etc/selinux/plat_sepolicy.cil`；如存在 userdebug 平台策略也会同步修补。`plat_file_contexts` 标记脚本 exec type，`plat_sepolicy_and_mapping.sha256` 会更新，使 init 放弃旧 precompiled policy 并按当前 split CIL 重编译。

开机完成及 `persist.sys.locale` 变化时，oneshot 服务以 Android `system` UID/GID 和 `u:r:fake_device_params:s0` 运行。策略只额外允许读取 system 模板、执行 shell/toybox 和访问 `system_app_data_file`，不依赖 Magisk、KSU、`su`、adbd 或其他固定 root 域。当前只处理 user 0。

缓存格式、UID/GID 1000 与专用域写入已在一加 15 DSU 上通过临时候选策略和短时 Enforcing 验证；init 依据 rc 自动完成开机转换仍需在下一次 DSU 启动后确认。
