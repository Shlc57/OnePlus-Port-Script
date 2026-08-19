# 验证与交付

## 落盘前 Enforcing 热测

先在工作树外从当前 AVC、正确标签和服务契约整理最小候选规则。取得 adb 授权并确认 `ro.gsid.image_running=1` 后，按 `$runtime-hot-patch` 的约束记录基线，并确认：

```bash
adb shell 'getenforce; getprop init.svc.<service>; ps -AZ | grep <process>'
adb shell 'service check <aidl-instance>'
```

对当前策略已经存在的类型，使用当前 DSU 已安装且来源明确的 ksud；先执行 `sepolicy check`，再临时 `patch`/`apply`。保持 Enforcing，重载最小消费者并复现同一业务操作，验证服务稳定、实例可发现、真实接口或用户流程成功，且没有 crash loop、linker 错误或新增 AVC。临时 tmpfs、live policy、日志时间窗与恢复边界必须记录。

一次只热测证据支持的一小组权限。live policy 通常只能增加、不能可靠撤销；若注入了过宽或错误规则，当前启动状态已被污染，后续收窄后的成功不能证明最小规则独立有效。需要干净状态重测时，重启及 DSU single-boot 必须另获用户同意；不能重启则如实记录验证边界。

热测成功后，才把实际必要规则转换为所属业务补丁的 CIL、contexts 和 metadata。不得把 ksud 命令或 `profile set-sepolicy` 当作项目落盘方案。新类型、完整 domain transition、开机加载 contexts 等无法可靠热加载的部分，先热测当前策略能够覆盖的行为，再通过完整 split policy 编译与冷启动验证补齐结论。

如果没有已授权设备、当前不是 DSU、ksud 不可用或规则没有安全的热加载路径，记录原因后可以继续静态固化，但交付必须将 Enforcing 热测标为未完成；静态结果不能冒充运行时证据。

## 落盘后的静态与行为测试

修改 Shell、Python、CIL 或 metadata 后至少运行项目要求的检查：

```bash
git diff --check
rg --files -g '*.sh' -0 | xargs -0 -n1 bash -n
PYTHONDONTWRITEBYTECODE=1 python3 -c 'import ast, pathlib; ast.parse(pathlib.Path("partition_metadata.py").read_text(encoding="utf-8"))'
python3 common/fix_vendor_avc/test_patch_vendor_avc_policy.py
python3 common/fix_mi_account/test_selinux_bundle.py
bash common/selinux_merge/test_selinux_bundle.sh
python3 common/selinux_merge/test_selinux_merge.py
```

对所有修改过的 Shell 运行 ShellCheck。bundle/context 测试至少覆盖：

- 完全未启用时安全跳过、完整交付时启用、部分 requirement 存在时失败；
- 清单字段、未知目标、重复项、符号链接和路径越界失败；
- fragment 类型缺失、重复 key、错误标签失败；
- escaped/unescaped key 视为同一路径；
- vendor/precompiled/metadata 各目标写入后 key 唯一；
- 再次合并得到完全相同字节结果；
- normal 与 debug CIL 使用同一 fragment 集合。

## 完整 split policy 编译

使用当前工作树实际加载的 plat、mapping、genfs、system_ext、product 与 vendor CIL 集合，不只单独解析 fragment。按设备/工程的真实参数调用 `secilc`，至少保留：

- policy version 与 mapping/API；
- 完整输入文件列表；
- 返回码；
- neverallow 是否启用；
- 输出 policy 的生成位置与清理方式。

当前 Android 16 init 的 split-CIL 编译带 `-N`；更换平台版本时重新核对目标 init 参数。先把开机等价的 normal/debug 完整编译作为启动可用性门槛；再去掉 `-N` 做额外 neverallow 审计。若审计命中移植前已经存在的跨分区冲突，应与未加入本次 fragment 的基线比较并单独报告，不能误归因于新规则；若命中新类型或新 allow，则仍须修正，不能用 `-N` 掩盖。

单独 fragment 合并成功只能证明语法和局部符号；开机等价的完整 `secilc` 成功才证明当前 split policy 没有未解析类型、属性或 class permission。额外 neverallow 审计的状态必须另行说明。

## 冷启动确认

永久文件进入新的 DSU 启动后，再记录：

```bash
adb shell 'getenforce; getprop init.svc.<service>; ps -AZ | grep <process>'
adb shell 'service check <aidl-instance>'
```

确认本次启动没有沿用 tmpfs bind mount 或 KernelSU 持久 profile，进程进入预期域，服务稳定运行、实例可发现、真实接口或用户流程成功，且没有 crash loop、linker 错误或新增 AVC。

不要为验证永久新类型擅自重启。重启及 DSU single-boot 必须另获用户同意；没有冷启动条件时，把独立域与开机 contexts 验证列为未完成项。

## 交付措辞

明确分级：

- `静态验证`：语法、测试、完整 CIL 编译；
- `Enforcing 热测`：当前策略加临时标签/allow 后服务和功能可用；
- `冷启动确认`：从未污染状态按固化文件启动，进程进入预期独立域且功能成功。

README 与最终回复只能声明实际达到的级别。保留日志证据位置，说明未验证项；不要把“临时域下越过卡死”写成“固化独立域已实机验证”。
