# 永久策略与 contexts 设计

## 1. 先诊断标签，不先写 allow

记录失败进程的 executable、init service、`ps -AZ` 域、`ls -Z` 标签、AIDL/HIDL 注册状态、linker 报错和 AVC。若 vendor daemon 被标成平台域或无关 HAL 域，先恢复专属 `*_exec` 与 domain transition。

Android linker namespace 与 SELinux domain 共同参与库可见性。典型信号是文件存在且 ELF 依赖正确，但进程在某个错误域中报告 `CANNOT LINK EXECUTABLE ... library ... not found`。给错误域增加文件 read allow 不是可靠修复。

## 2. 从原包抽取最小契约

围绕目标域在原包策略中查找：

- `(type ...)`、`roletype`、`typeattribute` 与 `typeattributeset`；
- init 到 executable 的 `typetransition`、entrypoint 和 process 权限；
- service manager/hwservice manager/vndservice manager 的 add/find 与 Binder 双向调用；
- property_contexts 及 get/set 所需 file/property_service/socket/connectto；
- 数据目录、firmware、TEE/QSEE、设备节点与 fd use；
- 客户端属性集和 public/protected service 属性；
- 相邻 neverallow 和 Treble 边界。

不要整段复制与目标服务无关的源策略。每条权限应能关联到服务契约、原包规则或当前 Enforcing 证据。

## 3. 类型与属性

独立 native 服务通常至少需要 domain、exec type 和 service type。按实际语义加入：

- domain：`domain`，HAL server/client 属性；
- executable：`file_type`、`exec_type`、`vendor_file_type`；
- `/data/vendor` 数据：`file_type`、`data_file_type`；
- vendor property：`property_type`、`vendor_property_type`，只有真实公共接口才加入 public property 属性；
- AIDL service：`service_manager_type`，以及真实需要的 `hal_service_type` / `protected_service`。

属性集合决定宏化 allow 与 neverallow。不能只为了通过编译随意加入 client/server/public 属性。

## 4. contexts 与 metadata

- executable 标签必须同时进入开机实际加载的 vendor/precompiled file_contexts；位于 odm 的真实文件路径还要覆盖最终 odm metadata contexts。
- service name 必须与 rc/VINTF/AIDL instance 完全一致，并同步 vendor 与 precompiled service_contexts。
- property key 使用原包精确契约；不要用宽泛 `persist.vendor.` 前缀替代一组安全敏感属性。
- `/data/vendor/...` 只属于运行时 file_contexts；不要写入分区打包 contexts/fsconfig。
- 新增分区文件、目录或符号链接必须有最终分区 fsconfig。仅重标已有 executable 且 mode/owner 不变时，不需要改 fsconfig 值，但必须确保原条目存在。

## 5. 失败策略

缺失来源、类型、context 目标或 rc 契约时，在任何写入前失败。不要回退到无关核心域，不要放宽通用 merge 函数，也不要以 wildcard allow、permissive domain 或 `dontaudit` 隐藏问题。
