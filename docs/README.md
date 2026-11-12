# 和鸣文档

这里描述当前 Windows / Android 实现、使用方式与验证边界。项目概览见[首页](../README.md)，功能变化见[版本记录](../CHANGELOG.md)。

## 使用和反馈

| 文档 | 内容 |
| --- | --- |
| [使用指南](user-guide.md) | 安装、组队、导入转换、分组、试听、外观与常见问题 |
| [产品行为规格](v1-spec.md) | 主从权限、队列、成员锁定和异常处理 |
| [贡献指南](../CONTRIBUTING.md) | 反馈问题、提交变更与验证要求 |

## 开发参考

| 文档 | 内容 |
| --- | --- |
| [构建与测试](build-and-test.md) | 开发环境、两端构建、自动化与集成测试 |
| [技术架构](architecture.md) | Flutter、共享内核、系统适配与数据流 |
| [目录结构](project-structure.md) | 源码职责、工具和本地存储 |
| [局域网协议](protocol.md) | 发现、控制消息、任务标识、音频传输与校时 |
| [音频内核](audio-engine.md) | 缓冲、调度、输出、转换与诊断 |
| [界面与主题](mobile-design.md) | 移动与桌面布局、明暗模式、六种主题色 |

## 状态和验证

| 文档 | 内容 |
| --- | --- |
| [开发状态](development-status.md) | 当前实现、最近验证与尚未完成的工作 |
| [真机验证摘要](physical-device-validation.md) | 按版本和场景区分的实际结果 |
| [后续验证计划](prototype-plan.md) | 声学测量、多设备容量和系统兼容性 |

`v1-spec.md`、`prototype-plan.md` 保留原文件名以维持链接稳定，内容已整理为当前行为和后续计划。公开文档不依赖维护者电脑上的日志或截图。

## 本地包与工具

- [heming_audio](../packages/heming_audio/README.md)：共享 C ABI、Dart FFI 与原生音频内核。
- [heming_platform](../packages/heming_platform/README.md)：系统事件、后台播放与媒体处理。
- [Android 焦点验证助手](../tools/android-focus-probe/README.md)：开发用可控音频焦点工具。
- [第三方组件声明](../packages/heming_audio/THIRD_PARTY_NOTICES.md)：原生依赖来源与许可。
