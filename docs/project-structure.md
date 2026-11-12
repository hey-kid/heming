# 项目结构

和鸣采用一个 Flutter 主工程和两个仓库内包。Windows 与 Android 共用页面、资源库和会话控制，音频内核与系统生命周期分别封装。当前支持范围见 [项目首页](../README.md)，构建步骤见 [构建与测试](build-and-test.md)。

## 目录概览

下列目录均对应当前实现；不是尚未落地的模块规划。

```text
heming/
├─ lib/
│  ├─ main.dart                 # 初始化与生命周期协调
│  ├─ app/                      # 导航、主题、偏好、公共界面组件
│  ├─ features/
│  │  ├─ devices/               # 设备发现、组队、成员与输出设置
│  │  ├─ library/               # 资源导入、转换、分组与本机试听入口
│  │  ├─ playback/              # 当前任务、队列、切歌与结束播放
│  │  └─ settings/              # 设备名称、明暗模式、主题色
│  ├─ data/                     # SQLite 索引、资源文件与转换管理
│  ├─ networking/               # mDNS 发现与 WebSocket 控制连接
│  ├─ session/                  # 角色、成员、任务、队列和媒体状态协调
│  ├─ preview/                  # 独立本机试听控制
│  └─ shared/                   # 共用模型
├─ packages/
│  ├─ heming_audio/
│  │  ├─ lib/                   # Dart FFI API 与试听封装
│  │  ├─ hook/build.dart        # 原生资产编译与打包
│  │  ├─ src/
│  │  │  ├─ heming_audio.cpp    # 同步引擎、媒体处理、平台输出和传输
│  │  │  ├─ heming_audio.h      # C ABI
│  │  │  ├─ preview_player.cpp  # 独立流式本机试听
│  │  │  ├─ sync/              # 硬件时钟与输出时序算法
│  │  │  ├─ tests/             # C++ 原生测试
│  │  │  └─ vendor/            # 固定版本原生依赖
│  │  └─ test/                 # Dart 媒体与回环测试
│  └─ heming_platform/
│     ├─ lib/                   # 平台 API 与事件
│     ├─ android/               # Kotlin 焦点、媒体服务、系统解码
│     ├─ windows/               # C++ 系统事件、电源请求、系统解码
│     └─ test/                  # 平台接口测试
├─ android/                     # Android 应用入口与打包配置
├─ windows/                     # Windows 原生窗口与打包配置
├─ test/                        # 应用逻辑与界面测试
├─ integration_test/            # 真实平台与网络集成测试入口
├─ test_driver/                 # 已安装 Android 测试包的驱动
├─ tools/                       # 构建、验证、素材与诊断工具
└─ docs/                        # 用户与开发者文档
```

`build/`、`.dart_tool/`、`.local/` 和 `dist/` 是本机构建、诊断或分发输出，不是应用数据目录。不要把构建缓存、设备日志、用户音频或签名私钥提交到仓库。

## 应用层职责

### 界面与偏好

- `app/heming_app.dart` 组合页面、状态区、桌面侧栏和移动底栏。
- `app/theme.dart` 根据明暗模式、主题色和布局密度生成主题。
- `app/theme_accent.dart` 定义六种精选颜色、稳定标识和名称；`theme_color_picker.dart` 提供共用选择器。
- `app/preferences.dart` 独立保存明暗模式和主题色，通知界面更新，不重建会话或音频引擎。
- `mobile_components.dart` 与 `desktop_components.dart` 分别处理紧凑分组和桌面自适应分栏。

视觉规则见 [界面设计](mobile-design.md)。页面调用现有控制器，不在界面中维护第二份播放状态。

### 资源与试听

`data/library_repository.dart` 保存 SQLite 索引、分组和偏好；`library_controller.dart` 协调导入、检测、显式转换及播放前校验。`native_media_backend.dart` 组合原生音频包与系统媒体解码能力。

`preview/` 是未组队时的独立试听控制器，支持暂停和定位。它不建立同步播放组，创建或加入组前停止试听；同步播放与试听的交互规则不能混用。

### 会话与网络

`session/session_controller.dart` 负责主从角色、加入审批、播放队列、READY 屏障、主控移交和异常恢复。`native_audio_session_port.dart` 将这些操作映射到原生引擎；`media_playback_publisher.dart` 将当前任务状态镜像给 Android 系统媒体控件。

`networking/` 处理发现和控制消息。PCM 音频数据及校时由原生包直接传输，不逐块经过 Flutter 平台通道。详细边界见 [架构](architecture.md) 与 [协议](protocol.md)。

## 两个本地包

### heming_audio

[音频包](../packages/heming_audio/README.md) 提供 C++ 内核和 Dart FFI 封装，负责媒体检测、手动转换、PCM 缓冲、TCP/UDP 传输、预约开始、硬件时钟估计、漂移修正及本机输出。

Windows 使用 WASAPI，Android 使用 AAudio。平台分支目前主要集中在 `src/heming_audio.cpp`，独立试听位于 `src/preview_player.cpp`；不存在规划式的空 `engine/`、`transport/` 或 `media/` 目录。

`hook/build.dart` 为 Flutter/Dart 构建原生资产，CMake 提供独立测试入口。转码与网络等待不在音频回调线程执行。

### heming_platform

[系统插件](../packages/heming_platform/README.md) 负责焦点、前台服务、系统媒体状态、真实休眠/输出变化事件，以及系统支持格式的音轨提取。它不创建第二套同步播放器。

Android 的 `HemingPlaybackService` 持有播放期前台服务、MediaSession 及运行所需的锁；插件报告焦点变化。Windows 插件管理播放期电源请求和默认输出设备事件。平台层报告事件，是否退出播放组由会话控制器决定。

根目录的 `android/`、`windows/` 是应用壳，包里的同名目录是可复用平台实现。iPhone、iPad、Mac 的应用壳与平台适配尚未实现。

## 运行时数据

每台设备使用系统提供的应用数据目录；资源不进入仓库或 Flutter `assets/`。

```text
应用数据目录/
├─ database/heming.sqlite       # 资源索引、分组及本机设置
├─ library/
│  ├─ originals/              # 原样导入的资源副本
│  └─ playable/               # 转换并校验成功的统一规格副本
└─ temp/                      # 临时媒体输出
```

导入保留原始文件和格式；生成的播放副本与原件分开。同步播放的五秒 PCM 缓冲在内存中，与完整磁盘资源不同。资源分组只修改元数据，删除分组不会删除音频文件。

## 修改代码时的边界

| 修改目标 | 主要位置 |
| --- | --- |
| 页面布局、主题和设置 | `lib/app/`、`lib/features/` |
| 导入、分组、转换规则 | `lib/data/` |
| 组队、队列、权限和主控移交 | `lib/session/`、`lib/networking/` |
| 同步、缓冲、解码和出声时序 | `packages/heming_audio/` |
| 焦点、通知、后台与系统事件 | `packages/heming_platform/` |
| 应用启动窗口、平台打包 | 根目录 `windows/`、`android/` |

开发前先确认变更属于哪一层，再选择 [对应测试](build-and-test.md)。验证完成情况与限制见 [开发状态](development-status.md)。
