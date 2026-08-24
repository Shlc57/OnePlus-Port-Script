# HAL 与独立 init 服务重载方法

先把 init service 名、进程/可执行文件名、AIDL instance 和 HIDL instance 分开确认，并从 rc、进程状态和服务注册表交叉核对。

记录旧 PID、状态、接口、目标 hash/context 和日志基线。把候选文件放入 tmpfs 后挂载到解析出的具体目标；替换库或二进制后，重载真正读取它的 init service，必要时再处理最小客户端。

Composer/HWC 是 SurfaceFlinger 的长期客户端。如果重载 Composer，必须把 SurfaceFlinger 纳入同一重载窗口并确认新连接；只重载 Composer 不会让现有 SurfaceFlinger 自动切换到新 Composer。

重载后检查 PID 或启动时间变化、接口重新注册、真实调用结果以及 linker/VINTF/SELinux/崩溃日志。恢复时卸载精确挂载并按原状态启动；遇到 busy、循环崩溃或无法确认目标边界时停止扩大范围。
