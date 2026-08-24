# system_server 与 framework 服务重载方法

先判断目标是否能通过配置 reload、observer、package/process restart 或单个 native service 完成；只有需要重建 framework 缓存时才扩大到 system_server/zygote。

system_server 不是普通 init service。优先使用当前 ROM 提供并经 help/rc 确认的 userspace restart 接口；若必须触碰 zygote，先记录旧 PID、boot 状态、日志和恢复方案，并把 UI 中断与 crash loop 风险纳入实验窗口。

重载后有限等待 zygote、system_server、PackageManager/ActivityManager/WindowManager 和目标 Binder 服务恢复，检查新 PID、接口调用、SystemUI/launcher、崩溃和 ANR。无法稳定恢复时停止重试，优先卸载临时挂载并回到原状态。

framework 热重载只说明当前运行时和缓存条件下可用；签名、classpath、contexts/fsconfig 和下一次冷启动仍需单独验证。
