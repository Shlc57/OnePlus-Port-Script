# HyperOS appname 音频卡顿修复

本特性补丁用于 HyperOS 上层音频策略库搭配 Oplus 底包 Audio HAL 的场景。HyperOS 在应用开始或停止发声时会向音频流下发 `appname=+包名` 或 `appname=-包名`；Oplus HAL 不支持该私有参数并返回 `BAD_VALUE`，可能使 AudioFlinger 将输出流切入 standby 后再唤醒，形成约 200 ms 的卡顿。

## 修补范围

补丁只处理两个 `system_ext/lib64` ARM64 库：

| 文件 | 导出函数语义范围 | 调用点数量 |
| --- | --- | --- |
| `libaudiopolicymanagerimpl.so` | `AudioPolicyManagerImpl::setAppNameParameter` 与 `setParametersForSystemClient` | 2 + 1 |
| `libmiaudiopolicymanager.so` | `MiAudioPolicyManager::startInput` 与 `stopInput` | 3 + 2 |

目标调用是从音频流对象虚表偏移 `0x60` 取出 `setParameters` 后执行的 `blr x8`（`00 01 3f d6`），修补后替换为 ARM64 `nop`（`1f 20 03 d5`）。这是无法通过属性或 XML 阻止的库内虚函数调用，因此采用最小二进制定点修补。补丁不修改 32 位库，也不改动其它音量、路由或硬件控制调用。

## OTA 适配与安全拒绝

补丁不记录、不比较、也不输出输入或输出系统库的完整摘要，不以固定文件大小作为准入条件。它会自行解析 ELF，并通过以下契约定位调用点：

- 文件必须是 little-endian ELF64 AArch64 共享库，程序头、节表和符号表边界必须有效。
- 目标导出函数必须各自唯一，并具有非零函数范围；函数范围必须完整落在可执行 `PT_LOAD` 中。
- 每个调用点通过函数语义范围、虚表 slot `0x60` 读取、参数寄存器准备以及调用后字符串处理指令共同定位。
- 每种指令形态的命中数必须严格符合表中的 3 + 5 个；歧义、缺失、未知周边代码或未知调用指令都会在写入前失败。

因此，OTA 只要保留相同函数和机器码语义，即使文件整体长度、其它内容或函数文件偏移改变仍可定位。若编译器改变了寄存器分配或控制流，补丁会安全拒绝，而不会按旧偏移猜测。需要先重新反汇编确认新语义，再显式更新锚点契约。

## 幂等与 metadata 约束

- 所有语义锚点均为 `blr x8` 时判定为原始状态并修补。
- 所有语义锚点均为 `nop` 时判定为已完成，重复执行不写入。
- 原始与 NOP 混合、任一点为其它指令，或锚点数量不符时拒绝处理。
- 两个存在的目标会先全部通过二进制与 metadata 预检，再在 `mktemp` 临时副本中修补并用 `replace_file_if_different` 写回。
- 单个目标文件不存在时只警告并跳过该文件。
- 目标路径必须已在 `system_ext` contexts 中唯一标记为 `u:object_r:system_lib_file:s0`，并在 fsconfig 中唯一登记为 `0 0 0644`。本补丁不新增或放宽 SELinux 规则。

若把修补后的库脱离本工程、改用 KSU/Mountify 等方式单独挂载，挂载文件仍必须具有 `u:object_r:system_lib_file:s0` 标签；错误标签可能导致 audioserver 拒绝加载。该运行时挂载方式不属于本特性补丁的输出范围。

## 验证边界

可执行以下主机侧契约测试，它只修补临时副本：

```bash
PYTHONDONTWRITEBYTECODE=1 python3 features/fix_audio_appname/test_contract.py
```

测试确认只修改 8 条登记指令、重复执行幂等，并拒绝混合状态、未知调用指令和错误 ELF 架构。主机侧检查不等同于 Enforcing 运行测试或刷机后的冷启动验证。
