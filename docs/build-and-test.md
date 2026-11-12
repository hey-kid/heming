# 构建与测试

本指南面向从源码运行和修改和鸣的开发者。除特别注明外，命令在仓库根目录的 PowerShell 中执行。应用使用同一份 Dart 代码构建 Windows 与 Android，当前应用版本见 [`pubspec.yaml`](../pubspec.yaml)。

## 开发环境

| 项目 | 要求或已验证配置 |
| --- | --- |
| Flutter / Dart | 已验证 Flutter 3.44.6 / Dart 3.12.2；Dart 约束为 `^3.12.2` |
| Windows | Visual Studio 的“使用 C++ 的桌面开发”工作负载及 Windows SDK；当前交付 x64 |
| Android | Android SDK 36、NDK `27.1.12297006`、Android Studio 配套 JDK；源码使用 Java 17 目标 |
| Android 设备 | Android 8.0 / API 26 起；当前交付 ARM32 和 ARM64 |
| 原生独立测试 | CMake 3.22 或更新版本、C++17 编译器 |
| 可选工具 | FFmpeg 仅用于生成开发测试素材，不是应用运行依赖 |

依赖由根目录和本地包的 `pubspec.lock` 记录。先确认工具链并获取依赖：

```powershell
flutter doctor -v
flutter pub get
```

如果 Windows 在生成插件符号链接时失败，且依赖已下载完成，可以使用仓库脚本创建项目内 junction：

```powershell
.\tools\prepare-windows-links.ps1
```

随后使用下文的 `--no-pub` 命令。重新执行 `pub get` 后可能需要再次生成链接。脚本不修改系统权限设置；SDK、IDE 路径和个人签名文件均应保留在本机。

## Windows

开发运行：

```powershell
flutter run -d windows --no-pub
```

构建并生成便携包：

```powershell
.\tools\package-windows.ps1
```

产物为 `dist/heming-windows-x64.zip`。脚本执行 Release 构建，加入 Visual C++ 运行库及原生依赖声明，再压缩完整运行目录。解压后运行 `heming.exe`，不要单独移动 EXE。

只构建、不打包时：

```powershell
flutter build windows --release --no-pub
```

输出目录为 `build/windows/x64/runner/Release/`。已有最新 Release 构建时可用 `package-windows.ps1 -SkipBuild` 打包。同一工作区不要并行执行 Windows Debug 和 Release 构建，两种模式会共用 Flutter 的临时构建目录。

## Android

构建同时包含 ARM32 / ARM64 的 APK：

```powershell
.\tools\build-android.ps1 -Mode release -TargetPlatform android-arm,android-arm64
.\tools\verify-android-release.ps1 -ApkPath build/app/outputs/flutter-apk/app-release.apk
```

调试包将 `-Mode` 改为 `debug`，输出为 `build/app/outputs/flutter-apk/app-debug.apk`。构建脚本默认只构建，不安装。

`verify-android-release.ps1` 检查预期 ABI、必要原生库、ELF 架构、包大小和 SHA-256；它不代替 Android SDK 的签名验证工具或实际安装测试。当前 Gradle 的 Release 配置使用开发签名，正式发行需自行配置专用签名。签名不同的 APK 不能直接覆盖已有安装。

### 安装与升级

先执行 `adb devices`，确认目标设备在线并已授权。将下方占位值替换为目标序列号：

```powershell
$deviceSerial = '替换为目标设备序列号'
adb -s $deviceSerial install -r build/app/outputs/flutter-apk/app-release.apk
```

如果设备要求在手机上确认安装，按其正常安装流程完成；也可以将 APK 复制至手机后使用系统文件管理器打开。命令失败不代表安装成功，完成后应核对设备中的版本。

升级使用同包名、同签名覆盖安装。不要以卸载、清除数据或关闭系统安全设置的方式处理安装失败，否则可能丢失资源库和偏好。测试入口 APK 也使用产品包名，应在专用测试设备上操作并保留可恢复的正常版本。

### 构建脚本说明

- 脚本将 Java 临时 socket 放在项目 `.local/java-uds` 中，命令结束后恢复环境变量。
- `-ProxyUrl` 可为本次构建指定 HTTP 代理，不会写入项目配置。
- Release 构建会临时过滤可能残留的 integration test 插件注册，结束后恢复生成文件。
- `-InstallTo` 是显式可选参数；日常构建不需要它。

## 自动化检查

界面、会话控制、资源库、偏好和平台接口测试：

```powershell
flutter analyze --no-pub
flutter test --no-pub test packages/heming_platform/test
```

独立 Dart 音频包测试：

```powershell
Push-Location packages/heming_audio
try {
    dart pub get
    dart test
} finally {
    Pop-Location
}
```

原生 C++ 算法与传输测试：

```powershell
cmake -S packages/heming_audio -B .local/native-tests -DHEMING_BUILD_TESTS=ON
cmake --build .local/native-tests --config Release
ctest --test-dir .local/native-tests -C Release --output-on-failure
```

本机试听测试会打开静音输出流，需要可用音频设备。额外的网络音频回环用例默认跳过，启用方式见 [音频包说明](../packages/heming_audio/README.md)。测试是否经过真实设备、哪些用例跳过，应在结果中分别说明。

## Windows 集成测试

以下入口使用真实 Windows 插件、音频后端和网络连接；逐条执行，不要与 Windows Release 构建并行运行：

```powershell
flutter test integration_test/device_smoke_test.dart -d windows --no-pub
flutter test integration_test/session_smoke_test.dart -d windows --no-pub
flutter test integration_test/queue_smoke_test.dart -d windows --no-pub
```

它们分别覆盖媒体处理、会话与主控移交、连续队列切换。测试使用合成素材和静音输出；软件帧数及播放状态不等同于扬声器声学同步精度。

## Android 跨设备集成测试

此流程适合需要保留设备中现有数据的开发验证。脚本连接**已安装的 debug 测试包**，不会构建、安装、卸载或清除应用数据。避免让常规 Flutter 安装流程在安装失败后自动卸载重试。

### 1. 准备静音诊断主机

在装有 FFmpeg 的开发机上生成合成素材，并保持诊断程序运行：

```powershell
New-Item -ItemType Directory -Path .local -Force | Out-Null
ffmpeg -hide_banner -loglevel error -f lavfi -i 'anullsrc=r=48000:cl=stereo' -t 1810 -c:a flac -sample_fmt s16 -n .local/stability-silence.flac
dart run tools/lan_audio_host.dart .local/stability-silence.flac 40
```

诊断程序监听 HTTP 端口 `19846` 及动态音频 TCP/UDP 端口。它没有产品的加入审批，只能在可信测试网络使用；测试结束后关闭。主机与手机必须能够通过局域网互通，USB 仅承载测试驱动连接。

### 2. 构建测试入口

在另一个终端设置诊断主机的实际局域网 IPv4 地址：

```powershell
$hostAddress = '替换为诊断主机的局域网IPv4地址'
.\tools\build-android.ps1 -Mode debug -TargetPlatform android-arm,android-arm64 -EntryPoint integration_test/device_smoke_test.dart -DartDefine @("HEMING_TEST_HOST=$hostAddress", 'HEMING_TEST_STREAM_SECONDS=1800', 'HEMING_TEST_REVERSE_SECONDS=300', 'INTEGRATION_TEST_SHOULD_REPORT_RESULTS_TO_NATIVE=false')
```

主机地址在构建时写入。未指定 `HEMING_TEST_HOST` 时，跨设备用例会跳过。测试包必须为 debug，Release 不提供该驱动所需的 Dart VM 服务。

### 3. 覆盖安装并连接

通过目标设备的正常安装流程覆盖安装测试 APK。确认安装的是预期版本，再保持应用可在前台启动：

```powershell
$deviceSerial = '替换为目标设备序列号'
.\tools\test-android-existing.ps1 -Serial $deviceSerial -StartApp -TimeoutSeconds 2400 2>&1 | Tee-Object -FilePath .local/lan-test.log
```

`-StartApp` 重新启动已安装的 debug 应用，并从本次进程日志发现 VM 服务地址。脚本建立临时 USB 转发，连接后继续执行，结束时清理自己创建的转发。若使用 `-VmServiceUrl`，必须传入从该次设备日志观察到的完整地址和认证路径，不能猜测或使用过期地址。

### 4. 验收并恢复正常应用

```powershell
.\tools\analyze-lan-validation.ps1 -LogPath .local/lan-test.log -ExpectedSeconds 1800 -OutputPath .local/lan-test-summary.json
```

检查退出码、完整日志和断言。跳过、连接失败、超时或没有结束标记的测试不能算通过。完成后重新构建默认 `lib/main.dart` 入口并覆盖回正常应用，确认资源库和偏好仍在；不要分发测试入口 APK。

## 手动回归范围

| 类别 | 建议检查 |
| --- | --- |
| 组队 | 自动发现、手动地址、加入审批、六台上限、播放期间拒绝加入 |
| 资源 | 原件不变、显式转换、失败清理、分组与排序、单曲和分组队列 |
| 播放 | 上一首/下一首、随机从下一首生效、自然结束、主控移交后不续播旧任务 |
| 本机试听 | 未组队可试听；暂停/定位；离开资源库、入组或回后台停止 |
| 系统事件 | Android 后台/锁屏、媒体通知停止、焦点让声与恢复；Windows 最小化与锁屏 |
| 异常恢复 | 真实休眠、输出变化、断网、硬件错误和缓冲耗尽后的停止与重新选主 |
| 界面偏好 | 窄屏/大字号、明暗模式、六种主题色、重启保存及覆盖安装数据保留 |

Android 可控焦点测试见 [焦点验证助手](../tools/android-focus-probe/README.md)。真实来电、其他播放器、蓝牙及不同厂商策略仍需单独验证。

已有结果与尚未覆盖的场景见 [验证摘要](physical-device-validation.md)。诊断字段含义见 [音频内核](audio-engine.md)；约 5 ms 同步精度、长期声学漂移和多台容量必须通过独立测量验证，不能由上述命令本身推断。
