# 修正 Oplus ADFR 与 MI SurfaceFlinger LTPO 链路

## 改动分区

| 分区 | 改动 |
| --- | --- |
| `odm` | 保持 MI LTPO 关闭，写入 Oplus ADFR 与 MI-SF automode 配置；生成 `odm/etc/selinux/odm_property_contexts`，并同步 ODM contexts/fsconfig。 |
| `vendor` | 写入 `debug.sf.enable_vrr_config=1` 与 `vendor.display.enable_hal_self_refresh=1`（目标文件存在时）。 |
| `vendor` | 对 OnePlus 15 的明确 AD296 输入，安装 Apollo DBV-to-nit XML、对当前底包 `libsdmcore.so` 做只读 `.rodata` 中的定点路径适配，并同步 XML 的 contexts/fsconfig。 |
| `system_ext` | 在 `miui-services.jar` 的 `DisplayManagerServiceImpl.onBootCompleted()` 注入 OnePlus ADFR RUS；若检测到本模块旧版本在 `DisplayFeatureManagerServiceImpl.init()` 写入的 Full-AOD replay，则精确移除该 replay；仅替换同时含两个目标类的 `classes.dex`，并在实际变化后清理该 JAR 的 profile、FS-Verity metadata 与分 ABI OAT/VDEX。 |

## 模块说明

目标设备使用 Oplus Composer/ADFR 面板链路。强制 `ro.vendor.mi_sf.ltpo.support=true` 会让 MI SurfaceFlinger 介入 60/120 timing-switch，与目标 144/165 timing 不匹配，因此模块会清理该属性（包括旧轮次残留）并保持 MI LTPO 默认关闭；真正的 LTPO 由 Oplus ADFR 链路负责。目标 `libmisurfaceflinger.so` 在 `ro.vendor.mi_sf.enable_tp_idle_automode=true` 时会把 `setTpIdleFps()` 的请求入口直接改写成 60Hz，因此模块会删除该开关（包括旧轮次残留），避免阻断面板低频匹配。`ro.vendor.mi_sf.supported_automode_maxfps_list` 会被设置为 `60,90,120,144,165`，使这些已枚举高刷具备 MI-SF automode 资格；该列表不是面板低频表，不能单独证明 1Hz/55Hz。虽然移植底包的 `libsdmcore` 将 `vendor.display.enable_qsync_idle` 作为一个可选分支门控，但原系统实测该属性为空而 LTPO 正常，且两边 `libsdmcore` 版本不同；模块因此不设置该属性，避免把未证实的通用 QSync 路径强加到 OnePlus 15。`persist.oplus.display.vrr.adfr` 必须由运行时实际加载的 `/odm/etc/selinux/odm_property_contexts` 标记为 `exported_system_prop`；只修改 `precompiled_property_contexts` 不足以修复 early-init 属性拒绝。当前面板 DTS 的 144/165 timing 仍缺少 `oplus,adfr-min-fps-mapping-table`、高精度映射和对应 min-fps 命令，模块不伪造这些二进制/DT 数据，也不猜写具体 1/55Hz idle 值；实际工作状态仍以冷启动后的运行时面板、SurfaceFlinger、HWC/ADFR 和 idle dump 为准。

OnePlus 15 组合入口显式传入 `devices/oneplus15/config/adfr2minfps.xml`。构建期先把这份原厂 AD296 RUS 输入严格编码为与原厂一致的 `int[225]`，再由 `miui-services.jar` 的显示 Handler 异步向 Oplus panel-feature AIDL 服务发送 transaction `2`、feature `234`。这里每个 XML vector 的 index 0 是原厂 `OplusHwDisplayXmlParseCommon` 写入的元素数量，实际 XML 数值从 index 1 开始；它不是普通的零填充数组。这样补的是移植 `system_server` 缺失的 RUS 调用者，不会在设备上解析 XML，也不会伪造面板 min-fps 命令。RUS helper 保持 `public`，由同一 DEX 中的 `OplusAdfrRusRunnable` 通过虚调用进入，避免跨类访问级别错误。

同一 JAR patcher 已撤销此前的 Full-AOD 初始化 replay，先隔离这个与真实 AOD 电源边沿可能竞态的变量。该 replay 会在 `DisplayFeatureManagerService` 的 LocalService 注册时把缓存状态重新发送到 SurfaceFlinger，现场表现可能是面板 TE 又回到 120Hz；这仍需冷启动 A/B 结果最终确认。新构建只注入 ADFR RUS loader，不再改写 `DisplayFeatureManagerServiceImpl.init()`；对于已经写入旧 replay 的 JAR，patcher 仅在其方法体与本模块旧载荷完全匹配时恢复原始 `init()`，遇到未知或半注入内容会拒绝覆盖。Patcher 只接受普通文件、要求两个目标类位于同一 `ZIP_STORED` DEX，回编译后仅增量写回该 DEX，并验证其他 JAR 条目内容不变；相同 payload 且无旧 replay 时跳过。该步骤需要本机构建环境的 `java`、`zip`、`unzip` 以及 `/snap/apktool/current/apktool.jar`。

此补丁没有实现原厂 RomUpdate 监听、`/data/system` 覆盖优先级、feature-233 预检、游戏黑名单或 `oplus_vrr_config.json` 的消费链。因此它尚不能静态保证 165Hz 会下探到 55Hz。刷入新镜像并冷启动 DSU 后，先检查 `logcat` 中的 `OPLUS_ADFR_RUS_SENT`，再观察 Composer plugin 的 RUS-loaded 状态和 `oplus-adfr2minfps` 的 min-fps 日志，最后分别验证 60/90/120/144Hz 的 1Hz 与 165Hz 的 55Hz；在此之前只属于主机侧 JAR 构建验证。

DSU 曾直接记录 `ApolloService ... error mParser`、`getadfrPanelNitFn ... ret 7`、`mPanelNit=0` 后把 min-fps 回退为 120；原系统同一时段则以非零 panel nit 算出并下发 `mMinfps=1`。OnePlus 15 组合入口因此明确提供原厂 AD296 的 Apollo 数据库 asset。由于底包 `libsdmcore.so` 的 Apollo parser 固定查找 `/my_product/vendor/etc/display_apollo_list_*`，而移植最终没有 `my_product` 分区，模块在当前受支持的库 SHA-256 上将该 `.rodata` prefix 改成等价的 `/vendor/etc/display_apollo_list_*`。这不能只改字符串：`ApolloXmlParser::parseXmlFile()` 同时将原前缀的 43 字节写为 `std::string` 长度与结尾位置；缩短后的路径若仍沿用该值，会包含中间 NUL 并在 `display_apollo_list_` 处截断。Patcher 因而一并验证并将这两条固定 `.text` 指令改为 32 字节长度/结尾，且只接受原始、已知的旧 prefix-only 输出或最终完整输出三种精确 hash 状态。它会验证输入库 SHA、固定文件偏移、路径唯一非执行只读 LOAD/`.rodata`、指令唯一可执行 LOAD/`.text` 与输出 SHA；未知库版本、错误 asset、非 AD296 XML 或已损坏的半修补状态均失败，绝不把此二进制定点修补套用到其他机型/底包。

AD296 asset 以 gzip+base64 存在 `devices/oneplus15/config/`，使仓库只保存一个精确原厂输入并可由 SHA-256 复原校验；它在构建期解压到最终 `vendor/etc/display_apollo_list_AD296_P_3_A0020_dsc_cmd_mode_panel.xml`。最终文件拥有 `vendor_configs_file` 标签与 `0:0 0644` metadata。该步骤补的是 panel-nit callback 的配置输入，不修改面板 DT、QSync 命令或 1/55Hz 数值。冷启动 DSU 后必须先确认 XML hash/context、无 `error mParser`/`ret 7`、`mPanelNit` 非零，以及 plugin 是否实际出现 `calculateMinfps() = 1`；165Hz 的 55Hz 仍须单独取证。

目标属性文件不存在时只警告并跳过。

## 执行

```bash
bash port_main.sh features/fix_ltpo
```
