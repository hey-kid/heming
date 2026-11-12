<p align="center">
  <img src="android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" width="76" alt="和鸣图标">
</p>

# 和鸣 · Heming

让同一局域网里的设备，一起播放同一段声音。

和鸣是一款面向 **Windows 和 Android** 的局域网音频同步播放器。电脑和手机都可以创建播放组、担任主控，或作为跟随设备播放。界面和业务基于 Flutter，共享 C++ 音频内核负责缓冲、校时与原生输出。

当前版本：**1.5.0+10**。项目仍在持续开发，已完成两端构建与部分真机验证；同步精度和设备容量的边界见[验证摘要](docs/physical-device-validation.md)。

[使用指南](docs/user-guide.md) · [构建与测试](docs/build-and-test.md) · [技术架构](docs/architecture.md) · [版本记录](CHANGELOG.md) · [文档目录](docs/README.md)

## 功能

- **多设备播放**：每组最多六台设备，支持自动发现、手动地址加入、主控审批和移交。
- **本地资源库**：导入音频或系统可解码的视频音轨，保留原件；需要时由用户手动生成统一播放副本。
- **分组与队列**：资源分组、批量管理、组内排序、上一首／下一首、顺序／随机播放；模式切换从下一首生效。
- **本机试听**：未加入播放组时，可临时试听资源，支持暂停和拖动进度。
- **后台播放**：维持已开始的后台与关屏播放；Android 接入媒体通知和系统媒体会话，其他音频占用时可临时让声。
- **统一外观**：桌面分栏与移动布局，浅色／深色／跟随系统，六种精选主题色，偏好在本机保存。

数据保存在本机，参与设备通过局域网传输音频，不需要搭建云端服务器。

## 平台

| 平台 | 当前状态 |
| --- | --- |
| Windows x64 | 已实现，提供便携目录构建与打包脚本 |
| Android 8.0 及以上 | 已实现，发布构建包含 ARM32 / ARM64；实际覆盖机型见验证文档 |
| iPhone / iPad / macOS | 尚未实现；待具备 Mac 编译与真机环境后推进 |

示例工程中的其他平台模板不代表对应平台已经受支持。

## 开始使用

1. 将设备接入同一局域网，在电脑和手机上打开和鸣。
2. 在一台设备上创建播放组，其余设备申请加入，由主控接受。
3. 主控导入资源。符合规格的文件可以直接播放，其余支持的格式需先点击“转换”。
4. 选择歌曲或分组；各设备完成缓冲后，按共同时间开始播放。

找不到播放组时，可以使用主控设备页显示的连接地址。完整操作与常见问题见[使用指南](docs/user-guide.md)。

### 安装包

源码仓库不包含生成的安装包。若仓库提供 Release 附件，Windows 下载 ZIP 后完整解压并运行 `heming.exe`；Android 使用 APK 安装。请以实际 Release 附件为准，文档中的本机构建产物路径不是下载链接。

当前 Android Release 构建仍使用开发签名，尚未提供正式商店发行或自动更新流程。也可以按[构建指南](docs/build-and-test.md)自行生成安装包。

### 从源码运行

已验证的开发环境为 Flutter 3.44.6 / Dart 3.12.2。Windows 需要 Visual Studio 的 C++ 桌面开发工具；Android 需要 SDK 与指定 NDK。完整环境说明见[构建指南](docs/build-and-test.md)。

在仓库根目录运行：

```powershell
flutter pub get
flutter run -d windows --no-pub
```

Windows 若因符号链接权限导致插件准备失败，在依赖已下载后运行 `tools/prepare-windows-links.ps1` 再重试。Android 开发和打包命令同样见构建指南。

## 播放规则与当前边界

- 同步播放资源使用 **FLAC / 48 kHz / 16-bit / 双声道**，主控解码后传输 PCM；目标缓冲为五秒。
- 缓冲和播放期间锁定成员；主控移交停止全组播放并清空旧缓存，回到待命。
- 同步播放支持切歌，不提供暂停续播或拖动进度；未组队的本机试听支持这些操作。
- 锁屏与真正的系统休眠不同。系统终止应用、输出变化、断网或缓冲耗尽仍可能结束播放。
- 六台是当前逻辑上限，尚未完成六台混合硬件的容量验收。**约 5 ms 是研究目标，不是已经测得的扬声器同步精度。**
- 项目面向可信局域网，当前传输没有 TLS 加密，不适合作为直接暴露到公网的服务。

Android 媒体卡片外观和焦点恢复受系统与厂商行为影响，实际已测范围见[验证摘要](docs/physical-device-validation.md)。

## 开发与贡献

欢迎提交可复现的问题、界面建议和代码改进。开始前请阅读[贡献指南](CONTRIBUTING.md)，技术细节从[架构说明](docs/architecture.md)和[目录结构](docs/project-structure.md)进入。

基础检查：

```powershell
flutter analyze --no-pub
flutter test --no-pub test packages/heming_platform/test
```

1.5.0 的 Flutter／平台测试为 **142 项通过**。历史结果不代替后续版本的回归，也不等同于声学测量；详见[开发状态](docs/development-status.md)。

## 许可证与第三方组件

原创代码的开源许可证尚未确定，当前不声明采用 MIT、Apache-2.0 或其他开源许可。现有本地包的 `LICENSE` 文件记录了这一状态。

第三方组件保留各自的许可。原生依赖与声明见 [THIRD_PARTY_NOTICES.md](packages/heming_audio/THIRD_PARTY_NOTICES.md)。应用没有分发开发机上的 FFmpeg 可执行文件。
