# heming_audio

和鸣的原生音频包，通过 Dart FFI 连接 C++ 内核。它负责媒体检测、显式转换、同步音频传输、预约播放和本机试听；组队、加入审批与播放队列由主应用协调。

当前平台为 Windows / WASAPI 与 Android / AAudio。包版本 `0.0.1` 是仓库内组件版本，不等同于主应用版本，也不表示已经发布到包仓库。

## 职责与入口

| 入口 | 用途 |
| --- | --- |
| `NativeAudioEngine` | 同步播放、TCP/UDP 传输、缓冲、预约开始与本机输出 |
| `NativeMedia` | WAV / MP3 / FLAC 检测、完整解码校验、转换 |
| `NativeConversion` | 转换进度、完成等待与取消 |
| `NativePreviewPlayer` | 不建立播放组的本机试听、暂停、定位 |

公开 Dart API 位于 [`lib/heming_audio.dart`](lib/heming_audio.dart) 和 [`lib/preview_player.dart`](lib/preview_player.dart)，C ABI 位于 [`src/heming_audio.h`](src/heming_audio.h)。音频采样、网络传输和解码留在原生层，不逐块经过 Flutter 方法通道。

## 同步播放生命周期

1. 主控调用 `prepareLocal(path:, sessionId:, taskId:)`，打开音频输出和本轮 TCP/UDP 服务。
2. 从机使用同一会话、任务标识调用 `prepareRemote(host:, port:, sessionId:, taskId:)`。
3. 等待所有设备准备完成，再调用 `scheduleStart(masterTimeUs)`，按主控单调时间预约开始。
4. 读取 `status` 或监听 `statuses` 获取进度、缓冲、校时和错误。
5. 结束时等待 `stop()`；退出时等待 `dispose()`。

准备阶段等待输出初始化、五秒 PCM 缓冲（或短文件 EOF），从机还需完成校时。`audioPort` 是本轮 TCP 音频与 UDP 校时共用的端口号。会话协调器负责汇总 READY，单台准备成功不代表全组可以立即开始。

`stop()` 先撤销输出，再异步清理设备、连接与缓存。自然结束等待最后一块音频排空后报告完成，避免连续切歌截断尾音；主动结束立即停声。已取消任务的迟到结果不能恢复旧输出。

### 本机输出和延迟补偿

`setOutput(volume:, channel:, muted:)` 设置本机音量、声道和静音，不影响其他设备。选择左/右声道时，该设备的两个输出声道均使用所选源声道。

`setLatencyCompensationMicros(value)` 是工程校准入口，范围为 ±250,000 µs。正值使媒体提前送出以补偿额外输出延迟；值在同一引擎实例的停止/准备间保留，跨启动持久化由上层负责。应在待命时使用固定输出路径的真实测量值，不用软件进度差直接推算扬声器补偿量。

## 媒体检测与转换

- `NativeMedia.probe(path)` 读取参数；`verifyDecode: true` 执行完整解码校验。
- `NativeMedia.convert(inputPath, outputPath)` 返回 `NativeConversion`，提供 `done`、`progress` 与取消操作。
- 输出统一为 FLAC、48 kHz、16-bit、双声道；源文件不被改写。
- FLAC 使用 verbatim 子帧，保留转换后的 PCM 样本，体积接近未压缩 PCM，不能据此预期常见 FLAC 编码器的压缩率。
- 输出路径已存在时拒绝覆盖；失败或取消清理部分输出。转换完成前再次完整解码校验，取消也覆盖校验阶段。

AAC、MP4 等额外格式由 [`heming_platform`](../heming_platform/README.md) 使用系统解码器读取或提取为临时 WAV，再交给本包转换。格式覆盖取决于设备解码器，应用未内嵌 FFmpeg。

应用资源库负责显式转码入口、单任务队列、文件索引及临时输出提交；本包不会在导入时自动转换。

## 本机试听

`NativePreviewPlayer.open(path)` 将资源准备为暂停状态；随后可调用 `play()`、`pause()`、`seek(positionMs)`、`setVolume(0..1)`、`stop()` 与 `dispose()`。

试听直接支持 WAV / MP3 / FLAC，也可播放已有的规范转换副本，不会自动转码。它使用独立解码线程和固定一秒 PCM 环形缓冲，不创建同步会话或网络 socket。自然结束留出设备尾音排空时间，上层在完成后释放试听焦点。

试听与同步播放是不同的生命周期。是否允许试听、离开资源库时何时停止，以及何时获取/释放焦点，由应用的 `PreviewController` 决定。

## 传输与同步边界

TCP 按样本位置拉取 PCM，每块最多4,800帧，每端环形缓冲固定240,000帧。UDP 用四时间戳采样估计时钟偏移，并在播放期间重新校时。回调按单调时间调度开始，再用有界的平滑采样率修正减少长期漂移。

每个会话和任务都有标识指纹，用于拒绝旧任务数据；这不是身份认证或加密。协议目前没有 TLS，仅适用于可信局域网。控制消息、端口和边界见 [协议说明](../../docs/protocol.md)。

Windows 读取 IAudioClock / WASAPI 队列，Android 读取 AAudio 时间戳以估计呈现时间。硬件混音、蓝牙和扬声器仍可能有额外延迟；实现这些机制不等于已测得约5 ms声学同步精度。

## 诊断字段

| 字段 | 含义与限制 |
| --- | --- |
| `playedFrames` / `positionSeconds` | 曲目的软件媒体帧数与按48 kHz换算的进度 |
| `hardwarePositionMicros` | 输出流位置，包含准备期静音，不能当作曲目进度 |
| `hardwareTimestampMicros` | 硬件位置对应的本机单调时间 |
| `hardwareClockSource` | 0：不可用，1：Windows IAudioClock，2：Android AAudio |
| `hardwareClockValid` | 最近硬件采样是否有效；无效时使用估计回退 |
| `hardwareRatePpm` | Windows 的硬件速率估计；Android 当前为未实现占位值0 |
| `outputUnderruns` | Android 实际 AAudio XRun；Windows 当前为未实现占位值0 |
| `phaseErrorMicros` | 相对组内时间线的软件呈现误差，不是录音测得的声学偏差 |

失同步保护使用持续、有效的硬件观测，避免单次启动异常导致误停。具体阈值和算法见 [音频内核说明](../../docs/audio-engine.md)。32位设备上超过2 GiB文件的随机访问尚未列入已验证支持范围。

## 构建与测试

Flutter/Dart 构建使用 [`hook/build.dart`](hook/build.dart) 编译原生资产；Windows 未提供编译器配置时使用 CMake 发现 Visual Studio 工具链。完整依赖要求见 [构建指南](../../docs/build-and-test.md)。

在本包目录执行：

```powershell
dart pub get
dart test
```

默认用例包含媒体转换、取消清理和本机试听。试听测试会打开实际输出设备，但测试音量为0。网络音频回环用例另需显式启用；建议在单独测试终端运行：

```powershell
$env:HEMING_AUDIO_DEVICE_TEST = '1'
dart test test/native_loopback_test.dart
```

从仓库根目录运行原生测试：

```powershell
cmake -S packages/heming_audio -B .local/native-tests -DHEMING_BUILD_TESTS=ON
cmake --build .local/native-tests --config Release
ctest --test-dir .local/native-tests -C Release --output-on-failure
```

这些测试覆盖传输分帧、硬件时钟估计、呈现时序及试听流。跨设备与声学验收须另做，已执行范围见 [验证摘要](../../docs/physical-device-validation.md)。

原生依赖的固定版本、来源、SHA-256和声明见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。该声明描述第三方依赖，不替代本项目自身的许可安排。
