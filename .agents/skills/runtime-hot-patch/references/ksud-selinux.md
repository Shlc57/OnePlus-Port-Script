# 使用 ksud 做最小运行时 SELinux 豁免

## 1. 先确认工具与版本

只使用当前 DSU 内已安装、可执行且来源明确的 ksud。KernelSU 的 userspace 路径随版本/安装方式可能变化；常见 v3.2.5 路径是 `/data/adb/ksud` 和 `/data/adb/ksu/bin/ksud`，但不能只凭路径认定版本。

```bash
adb shell 'for p in /data/adb/ksu/bin/ksud /data/adb/ksud; do [ -x "$p" ] && "$p" --version; done'
adb shell '<ksud-path> sepolicy --help'
```

当前命令若与参考不同，以设备 `--help` 为准并停止套用未确认语法。KernelSU v3.2.5 提供：

```text
ksud sepolicy check '<statement-or-file>'
ksud sepolicy patch '<statements>'
ksud sepolicy apply '<file>'
ksud profile get-sepolicy '<package>'
ksud profile set-sepolicy '<package>' '<statements>'
```

`profile set-sepolicy` 会写入 `/data/adb/ksu/profile/selinux/<package>` 并立即 apply，属于持久配置，不是纯临时命令。只有用户明确要求持久 profile 时使用；修改前先 `get-sepolicy` 保存原值。普通热测优先 `sepolicy patch/apply`。

## 2. 从 AVC 建立规则

保持 `getenforce` 为 `Enforcing`。清晰标记实验时间窗口，复现一次最小操作，再同时查看 audit/logcat/dmesg：

```bash
adb shell 'logcat -b all -d | grep -F "avc: denied" | tail -100'
adb shell 'dmesg | grep -F "avc: denied" | tail -100'
```

对每条 AVC 确认：

- `scontext` 是否为真实消费者域；root/adbd 的 `u:r:su:s0` 不能代表 system_server 或 HAL；
- `tcontext` 是否来自正确的 file/service/property label；如果标签错误，优先修正 label/context，而不是允许错误类型；
- `tclass` 与 permission 是否确实由目标操作需要；
- 是否是 Binder 双向链路、service_manager/hwservice_manager/vndservice_manager 注册/查找、fd use、property 或文件访问中的哪一段；
- 是否触及 neverallow、跨 Treble 边界或暴露敏感对象。运行时工具能注入不代表永久策略合理。

把规则收敛为准确的源类型、目标类型、class 和权限，例如：

```text
allow system_server_202504 vendor_example_service service_manager find
allow hal_example_default surfaceflinger binder call
```

类型名必须来自当前设备/项目 policy；版本化 `system_server_<API_VERSION>` 不能写死为示例值。禁止 `allow * * * *`、大括号批量猜权限、整域 `permissive`、`dontaudit` 掩盖问题，或直接接受未经审阅的 audit2allow 全量输出。

## 3. 先检查，再注入，再复现

单条规则：

```bash
adb shell '<ksud-path> sepolicy check "allow <source> <target> <class> <perm>"'
adb shell '<ksud-path> sepolicy patch "allow <source> <target> <class> <perm>"'
```

多条规则放在设备 tmpfs 文件中，先 check 文件，再 apply：

```bash
adb shell '<ksud-path> sepolicy check /dev/runtime-hot-patch.XXXXXX/rules.sepolicy'
adb shell '<ksud-path> sepolicy apply /dev/runtime-hot-patch.XXXXXX/rules.sepolicy'
```

注入后立即确认仍为 Enforcing，重载受影响的最小服务并重现同一操作。验证原 AVC 消失、没有出现新的下游 AVC，且目标功能确实成功。一次只增加由证据支持的一小组规则；不要在失败时不断扩大权限集合。

注意：v3.2.5 的 `patch/apply` 对语法解析并非都采用 strict 模式，`check` 才是必要的显式语法门。命令成功也不代表规则符合项目永久 CIL/Treble/neverallow 约束。

## 4. 生命周期与固化

live policy 通常是加法，不能可靠地从当前内核 policy 删除单条 allow。将其视为“直到重启”的污染状态；不要宣称通过再次 apply 即可回滚。重启需要用户明确同意，并遵守 DSU 单次启动约束。

若要固化结论：

1. 把每条规则关联到复现步骤和 AVC 证据；
2. 转换到本项目对应补丁拥有的 CIL fragment/统一合并入口，不要把设备临时命令写进通用工具；
3. 使用当前 `API_VERSION`、policy ABI 和现有类型校验；
4. 验证 normal/debug policy、metadata 与冷启动；
5. README 只能写“热测验证”或“冷启动确认”中实际完成的那一级。
