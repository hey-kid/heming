# Android 音频焦点验证助手

一个独立开发测试 APK，用于给和鸣制造可重复的外部音频焦点事件。包名为 `app.heming.focusprobe`，不会替换产品应用，也不打入产品安装包。

助手只使用公开 Android API，无录音、网络或存储权限。进入前台后申请指定焦点，启动 AudioTrack 连续写入全零 PCM，结束时停止播放器、放弃焦点并关闭 Activity。音频样本为零，不发声，也不修改系统音量。

## 构建

在项目根目录执行：

```powershell
.\tools\android-focus-probe\build.ps1
```

脚本使用 Android SDK 36、Build Tools 36.0.0、JDK 和现有 Android debug keystore，不调用 Flutter/Gradle、不下载依赖、不安装设备。缺少工具时先完成开发环境配置；可通过 `-AndroidSdk`、`-JavaHome`、`-BuildToolsVersion`、`-CompileSdk`、`-DebugKeystore` 指定本机工具。

默认产物为 `.local/focus-probe.apk`；每次构建使用独立的临时子目录。输出路径可通过 `-OutputPath` 修改。此 APK 是调试工具，不能作为和鸣产品发布。

## 安装与运行

在 `adb devices` 中确认目标手机在线并已授权。替换下方设备序列号后，通过正常设备安装流程安装助手：

```powershell
$deviceSerial = '替换为目标设备序列号'
adb -s $deviceSerial install -r .local/focus-probe.apk
adb -s $deviceSerial shell am start -W -n app.heming.focusprobe/.MainActivity --es focus gain --ei seconds 8
```

如果手机需要安装确认，可用系统安装器完成，不修改其安全设置。只有确认安装成功后才开始测试。

| 参数 | 可选值与含义 |
| --- | --- |
| `focus` | `gain`：永久焦点；`transient`：临时焦点；`duck`：短暂降音。默认 `gain` |
| `seconds` | 持续1–300秒，默认8秒 |

每轮等待 Activity 自动关闭后再开始下一轮。助手若收到丢焦点事件，会主动结束并记录，不会反复抢回焦点。

## 观察与判定

先让和鸣在测试播放组中播放合成素材，再启动助手。记录以下行为：

- 外部焦点生效时，只有本机临时让声，其他设备和时间线继续推进。
- 助手正常结束后，和鸣按可用平台信息恢复；用户的音量/静音选择保持。
- 失焦期间切项、结束或退出组后，旧恢复回调不会让旧任务重新出声。

读取助手日志：

```powershell
adb -s $deviceSerial logcat -d -s HemingFocusProbe:I
```

正常完成一轮应包含 `FOCUS_REQUEST result=1`、`PLAY_START`、约指定时长后的 `PLAY_END completed=true`、`FOCUS_ABANDON` 和 `FINISHED`。若中途出现 `FOCUS_CHANGE` 并提前结束，应检查是否有其他应用过早抢焦点，不能只凭最后恢复声音判断通过。

该工具验证可控焦点事件和真实 active player 状态。它不能代替实际通知、来电、第三方播放器及不同厂商系统测试；静音素材也不能证明实际降音幅度。完整验证步骤见 [构建与测试](../../docs/build-and-test.md)。

## 测试结束

可以正常关闭助手，或仅停止/卸载这个独立测试包：

```powershell
adb -s $deviceSerial shell am force-stop app.heming.focusprobe
adb -s $deviceSerial uninstall app.heming.focusprobe
```

不要将以上命令的包名替换为和鸣产品包。提交问题时保留必要的事件顺序和产品版本，并移除设备序列号、个人路径及无关日志。
