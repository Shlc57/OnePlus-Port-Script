# 永久策略与 contexts 设计方法

## 诊断

从 executable、init service、进程域、文件/服务/property 标签、接口注册和 linker 报错回溯失败链路。错误标签或错误 domain transition 往往比缺少 allow 更先需要修复。

## 取证

围绕目标服务对照原包策略和运行时 AVC，查看类型/属性、transition、service manager、property、数据目录、设备节点和相邻 neverallow。只提取服务实际需要的契约，不整段复制无关规则。

## 设计

按真实语义决定 domain、exec、file/data、property 和 service 类型及属性集合。service 名称、property key 和路径要与 rc/VINTF/AIDL/HIDL 以及实际加载的 contexts 对齐。

## 落盘

新增分区文件或链接时同步考虑最终分区的 contexts/fsconfig；运行时 /data 路径使用实际加载的 file_contexts。生成结果先做格式、符号、唯一性和策略编译检查，再稳定写回。
