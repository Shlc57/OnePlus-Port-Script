# 使用 ksud 做临时 SELinux 验证

先在当前 DSU 查找可执行 ksud，并以实际 `--help` 输出为准：

```bash
adb shell 'for p in /data/adb/ksu/bin/ksud /data/adb/ksud; do [ -x "$p" ] && { echo "ksud=$p"; "$p" --version; "$p" sepolicy --help; }; done'
```

从 AVC 提取 `scontext`、`tcontext`、`tclass` 和权限，确认标签和真实业务动作。优先写出覆盖面较大但限定源域、目标域和 class 的候选 allow，例如：

```text
allow hal_example_default vendor_example_device chr_file { open read write ioctl }
```

先检查再注入单条规则：

```bash
adb shell '<ksud-path> sepolicy check "allow <source> <target> <class> { <perm1> <perm2> }"'
adb shell '<ksud-path> sepolicy patch "allow <source> <target> <class> { <perm1> <perm2> }"'
```

多条规则写入设备 tmpfs 文件后再检查和应用：

```bash
adb shell 'work=$(mktemp -d /dev/runtime-hot-patch.XXXXXX) && echo "$work"'
adb push rules.sepolicy <tmpfs-workdir>/rules.sepolicy
adb shell '<ksud-path> sepolicy check <tmpfs-workdir>/rules.sepolicy'
adb shell '<ksud-path> sepolicy apply <tmpfs-workdir>/rules.sepolicy'
```

其中 `<ksud-path>` 是已确认的设备端 ksud 绝对路径，`<tmpfs-workdir>` 是上一步输出的目录。`check` 只验证规则可被解析，`patch` 适合单条字符串，`apply` 适合规则文件。若设备版本提供 `profile get-sepolicy`/`profile set-sepolicy`，后者会写入持久 profile，不属于普通热修补。

注入后保持 Enforcing，重放同一动作，观察原 AVC、下游 AVC、服务状态和功能结果。规则先用于确认路径可行，之后逐步删除无必要权限并重复验证，收敛成窄范围规则。live policy 通常持续到重启，不能按单条规则可靠撤销；需要持久化时，将已验证规则转换到项目补丁的 CIL/contexts/metadata，并另做静态和冷启动验证。
