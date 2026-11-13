# heming_platform

和鸣的 Windows / Android 系统适配插件，封装音频焦点、后台播放条件、系统媒体状态、输出变化、系统媒体解码及本机媒体扫描的平台能力。实际音频输出由 [`heming_audio`](../heming_audio/README.md) 负责，插件不创建第二套同步播放器。

包版本 `0.0.1` 是仓库内组件版本，与主应用版本分别管理。音频与生命周期 API 位于 [`lib/heming_platform.dart`](lib/heming_platform.dart)；扫描由主工程的 [`MediaScanSource`](../../lib/data/media_scan.dart) 使用独立通道接入。

## API 概览

| API | 职责 |
| --- | --- |
| `events` | 焦点变化、通知停止请求、输出变化和真实休眠事件 |
| `acquireAudioFocus` / `releaseAudioFocus` | 同步播放所需的焦点申请与释放 |
| `acquirePreviewAudioFocus` / `releasePreviewAudioFocus` | 独立本机试听焦点，不启动组队播放服务 |
| `setPlaybackActive` | 建立或释放准备/播放期所需的运行条件 |
| `updateMediaPlayback` | 将曲名、时长、进度、阶段和设备状态镜像到 Android 媒体控件 |
| `beginNativeOutputPreparation` / `endNativeOutputPreparation` | Android 原生输出准备前后的播放器快照与代次 |
| `resumeLocalAudioFocus` | 用户明确请求恢复本机声音 |
| `inspectMedia` | 仅读取系统可解析的音轨参数 |
| `extractAudio` / `cancelMediaExtraction` | 显式提取音轨到临时 WAV，支持取消 |
| `dispose` | 释放焦点、事件订阅和方法通道处理器 |

Windows 对仅属于 Android 的媒体状态/试听焦点接口使用无操作或相应的成功返回，调用端可以保持统一接口。`locked` / `backgrounded` 枚举保留兼容，但普通锁屏和后台切换不会直接产生终止播放动作。

## 媒体扫描通道

`heming_media_scan` 与原有 `heming_platform` 通道分开注册，不创建额外 `HemingPlatform` 实例、不覆盖焦点事件处理器。扫描和复制不启动播放器或前台服务；只有用户显式选择 `openMedia` 时交由系统播放器打开。

| 方法 | 平台 | 行为 |
| --- | --- | --- |
| `defaultFolders` | Windows | 返回当前用户音乐、视频、下载目录的 UTF-8 路径列表 |
| `scan` | Android | 按需请求权限并开始 MediaStore 查询，返回首批结果及权限范围 |
| `scanNext` | Android | 用 `scanId` 获取下一批，返回 `hasMore` 指示是否继续 |
| `cancelScan` | Android | 取消查询并关闭对应 cursor |
| `copyMedia` | Android | 将所选已授权媒体 URI 流式复制到应用私有目标，核对源文件快照 |
| `cancelCopy` | Android | 中断当前复制，清理未完成输出 |
| `copyPreviewMedia` | Android | 只将授权音频 URI 复制到临时缓存；参数同 `copyMedia`，使用独立任务 |
| `cancelPreviewCopy` | Android | 取消试听准备并等待文件清理，不取消扫描或正式入库 |
| `openMedia` | Windows / Android | 显式以系统播放器打开 `locator`；Windows 校验本地媒体路径，Android 授予只读 URI 访问 |
| `revealMedia` | Windows | 在系统文件夹中选中 `locator` 对应的本地媒体文件 |

Android 每批最多 200 项，提供来源 URI、名称、音频 / 视频类别、大小、修改时间、时长和文件夹信息。扫描结果只包含元数据。Dart 层合并批次、处理选择与取消；确认加入后，资源库控制器负责独立副本、SHA-256 内容去重、目标分组和索引提交。

## Android

### 播放服务与系统控件

[`HemingPlaybackService.kt`](android/src/main/kotlin/app/heming/heming_platform/HemingPlaybackService.kt) 是 `mediaPlayback` 前台服务，承载 MediaSession、通知及播放期 partial wake lock / Wi-Fi lock。应用壳复用 FlutterEngine，使 Activity 重建可以重新连接原会话。

系统媒体状态包含曲名、时长、进度、设备数和主从角色。只提供停止操作，不提供同步播放的暂停或拖动；具体通知和锁屏卡片外观由设备系统决定。Android 13+ 的停止使用自定义媒体动作，并绑定服务激活代次，防止旧卡片停止新任务。

`updateMediaPlayback` 只更新显示，不会启动服务、申请焦点或开始音频。服务也不会在应用进程被系统终止后自动重启旧任务。

### 焦点与恢复

[`HemingPlatformPlugin.kt`](android/src/main/kotlin/app/heming/heming_platform/HemingPlatformPlugin.kt) 使用 AudioManager 和公开播放器活动回调。临时失焦只要求本机降音/静音；会话层保持媒体时间线、连接及用户音量设置。

永久失焦后，仅在能辨认本机输出且观察到外部播放器停止并稳定时尝试恢复。信息不足或存在竞争时保持静音，由用户明确恢复；不保证所有播放器和厂商系统均可自动恢复。

已开始的播放及连续切项由运行中的服务维持。从后台待命首次开始新播放可能受到系统限制，需要回到前台重试。强行结束进程、厂商终止服务或网络失联不属于持续播放保证。

### 系统媒体解码

MediaExtractor / MediaCodec 负责系统支持格式的参数读取和音轨提取。提取必须由上层显式调用，输出为独立临时 WAV，取消或失败清理部分输出；当前临时 WAV 限制为4GB。格式支持取决于设备解码器。

### 媒体库与权限

[`HemingMediaScanner.kt`](android/src/main/kotlin/app/heming/heming_platform/HemingMediaScanner.kt) 独立处理 Activity 权限回调、分页查询和复制工作线程。只有扫描请求中的 `requestPermission: true` 才会按需打开系统授权；应用启动和恢复前台的普通刷新不主动请求权限。

Android 8–12L 使用 `READ_EXTERNAL_STORAGE`，13 及以上区分 `READ_MEDIA_AUDIO`、`READ_MEDIA_VIDEO`，14 及以上兼容 `READ_MEDIA_VISUAL_USER_SELECTED` 的部分视频授权。不申请所有文件访问权限。列表来自系统音频、视频集合，不将 URI 转换为真实路径来读取；文件路径仅作为显示和排除应用目录的辅助信息。

查询与复制均可取消。复制校验源大小与修改时间，只向应用私有目录的新目标写入；权限失效、源变化或取消时不会把部分文件作为已导入资源。Activity 离开导致授权无法继续时结束待处理请求，避免 Dart 永久等待。

## Windows

Windows 实现在 [`windows/`](windows/) 中，包含：

- Media Foundation 音轨检测与提取；耗时任务在工作线程执行，结果回到平台线程。
- 默认音频输出设备通知与真实休眠事件。
- 播放期 `PowerRequestSystemRequired` 请求，停止、休眠和析构时释放。
- 扫描通道的 `defaultFolders` 使用 `SHGetKnownFolderPath` 解析音乐、视频、下载目录，支持用户重定向与 Unicode 路径，去除重复目录；不创建或修改用户目录。

播放期电源请求允许关屏、锁屏和最小化，不阻止用户主动休眠。真正休眠、输出改变及硬件错误仍由会话控制器执行对应的停止规则。

Windows 文件枚举与复制由 Dart 扫描源异步执行，合并默认目录和用户添加目录，并排除应用资源目录及目录链接；原生插件提供系统目录位置，以及系统播放器打开和文件夹定位，不拼接命令行。

## 集成约定

应用保持一个 `HemingPlatform` 实例。生命周期推荐由单一协调器管理：

1. 监听事件，区分暂时焦点变化和真正中断。
2. 在准备/播放期间维持 `setPlaybackActive(true)`。
3. 把用户音量与系统临时让声因子分开，不让恢复事件覆盖用户选择。
4. 任务撤销后丢弃迟到回调，不恢复旧任务。
5. 退出前先停止媒体任务并释放播放期运行条件，再等待 `dispose()`。

从机退出、主控全组停止、重新选主等业务规则归主应用会话层，不应写入平台插件。

## 验证

从仓库根目录执行接口测试：

```powershell
flutter test --no-pub packages/heming_platform/test
```

真实插件、系统解码和跨设备输出的验证入口在主工程 `integration_test/`，具体步骤见 [构建与测试](../../docs/build-and-test.md)。

[Android 焦点验证助手](../../tools/android-focus-probe/README.md) 可生成可控外部播放器事件。它不能替代实际来电、其他音乐/视频应用及不同厂商策略的验证。接口实现、测试通过和真机测量是不同层次，已执行范围见 [验证摘要](../../docs/physical-device-validation.md)。
