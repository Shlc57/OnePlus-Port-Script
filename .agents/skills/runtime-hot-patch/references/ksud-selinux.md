# 使用 ksud 做临时 SELinux 验证

先查看当前 DSU 中可执行 ksud 的路径、版本和 sepolicy --help，以设备实际支持的命令为准。

从 AVC 提取 scontext、tcontext、tclass 和权限，确认标签和真实业务动作。优先写出覆盖面较大但限定源域、目标域和 class 的候选 allow，先用 sepolicy check 检查语法，再用临时 patch/apply 注入；功能恢复后逐步删除无必要权限，收敛成窄范围规则。

注入后保持 Enforcing，重放同一动作，观察原 AVC、下游 AVC、服务状态和功能结果。live policy 通常只适合当前启动的实验；需要持久化时，将已验证规则转换到项目补丁的 CIL/contexts/metadata，并另做静态和冷启动验证。
