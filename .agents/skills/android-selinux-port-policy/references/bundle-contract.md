# SELinux bundle 交接方法

把服务迁移和策略合并拆成两层：

- 业务补丁描述自己的文件、CIL 和 contexts，并提供启用所需的清单。
- 统一入口读取清单，把 normal/debug policy 与各类 contexts 合并到最终分区。

常见清单行可表达 require、policy 和 contexts 三类信息，字段通常为“类型、目标、相对路径”。contexts 目标可以映射到 vendor、odm metadata、property 或 service contexts 等最终文件。

新增依赖时，先由业务补丁补充清单和本地验证，再让统一入口处理合并；不要在下游入口重复解释具体服务契约。合并时按路径或 key 覆盖、去重，并保持再次执行结果一致。写入前检查来源和相对路径，写入后检查标签、策略声明和目标映射。
