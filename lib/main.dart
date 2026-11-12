import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:heming_platform/heming_platform.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';
import 'app/heming_app.dart';
import 'app/preferences.dart';
import 'app/theme.dart';
import 'data/library_controller.dart';
import 'data/library_repository.dart';
import 'data/native_media_backend.dart';
import 'preview/preview_controller.dart';
import 'preview/native_preview_audio_port.dart';
import 'session/media_playback_publisher.dart';
import 'session/native_audio_session_port.dart';
import 'session/session_controller.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HemingBootstrap());
}

class HemingBootstrap extends StatefulWidget {
  const HemingBootstrap({super.key});
  @override
  State<HemingBootstrap> createState() => _HemingBootstrapState();
}

class _HemingBootstrapState extends State<HemingBootstrap>
    with WidgetsBindingObserver {
  SessionController? _session;
  LibraryController? _library;
  Preferences? _preferences;
  PreviewController? _preview;
  HemingPlatform? _platform;
  MediaPlaybackPublisher? _mediaPublisher;
  StreamSubscription<PlatformInterruption>? _events;
  LibraryRepository? _repository;
  Future<void>? _cleanup;
  bool _foreground = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_initialize());
  }

  Future<void> _initialize() async {
    LibraryRepository? openedRepository;
    HemingPlatform? openedPlatform;
    LibraryController? openedLibrary;
    SessionController? openedSession;
    MediaPlaybackPublisher? openedPublisher;
    PreviewController? openedPreview;
    try {
      final repository = await LibraryRepository.open(
        await getApplicationSupportDirectory(),
      );
      openedRepository = repository;
      final platform = HemingPlatform();
      openedPlatform = platform;
      final library = LibraryController(
        repository: repository,
        media: NativeMediaBackend(platform),
      );
      openedLibrary = library;
      await library.initialize();
      final id = repository.setting('deviceId') ?? const Uuid().v4();
      repository.setSetting('deviceId', id);
      final name =
          repository.setting('deviceName') ??
          (Platform.isAndroid ? '安卓手机' : Platform.localHostname);
      late final SessionController session;
      final preview = PreviewController(
        audio: NativePreviewAudioPort(),
        canPlay: () =>
            _foreground && !session.isConnected && !session.isJoining,
        acquireFocus: platform.acquirePreviewAudioFocus,
        releaseFocus: platform.releasePreviewAudioFocus,
      );
      openedPreview = preview;
      session = SessionController(
        audio: NativeAudioSessionPort(platform: platform),
        deviceId: id,
        deviceName: name,
        platformName: Platform.isAndroid ? 'Android' : 'Windows',
        acquireAudioFocus: platform.acquireAudioFocus,
        releaseAudioFocus: platform.releaseAudioFocus,
        resumeAudioFocus: platform.resumeLocalAudioFocus,
        setPlaybackActive: (active) async {
          if (active) await preview.stop();
          await platform.setPlaybackActive(active);
        },
        validateTrack: (track) => library.validateForPlayback(track.id),
      );
      openedSession = session;
      await session.initialize();
      final mediaPublisher = Platform.isAndroid
          ? MediaPlaybackPublisher(
              session: session,
              publish: platform.updateMediaPlayback,
            )
          : null;
      openedPublisher = mediaPublisher;
      final savedVolume =
          double.tryParse(repository.setting('volume') ?? '') ?? 1;
      final savedChannel = AudioChannel.values.firstWhere(
        (channel) => channel.name == repository.setting('channel'),
        orElse: () => AudioChannel.stereo,
      );
      session.setOutput(
        volume: savedVolume.clamp(0, 1),
        channel: savedChannel,
        muted: repository.setting('muted') == 'true',
      );
      preview.setVolume(
        session.localDevice.muted ? 0 : session.localDevice.volume,
      );
      var outputKey = '';
      session.addListener(() {
        if ((session.isConnected || session.isJoining) && preview.isActive) {
          unawaited(preview.stop());
        }
        final device = session.localDevice;
        preview.setVolume(device.muted ? 0 : device.volume);
        final key = '${device.volume}/${device.channel.name}/${device.muted}';
        if (key == outputKey) return;
        outputKey = key;
        repository.setSetting('volume', device.volume.toString());
        repository.setSetting('channel', device.channel.name);
        repository.setSetting('muted', device.muted.toString());
      });
      _events = platform.events.listen((event) {
        switch (event) {
          case PlatformInterruption.previewFocusDucked:
            preview.setFocusAttenuation(0.2);
          case PlatformInterruption.previewFocusLost:
            unawaited(preview.focusLost());
          case PlatformInterruption.previewFocusGained:
            unawaited(preview.focusGained());
          case PlatformInterruption.audioFocusDucked:
            session.setFocusAttenuation(0.2);
          case PlatformInterruption.audioFocusLost:
            session.setFocusAttenuation(0);
          case PlatformInterruption.audioFocusGained:
            session.setFocusAttenuation(1);
          case PlatformInterruption.stopRequested:
            unawaited(
              session.isMaster
                  ? session.endPlayback()
                  : session.leave(reason: '本机已结束播放'),
            );
          case PlatformInterruption.outputChanged:
            unawaited(preview.stop());
            unawaited(session.handleInterruption('音频输出设备已变化'));
          case PlatformInterruption.suspending:
            unawaited(preview.stop());
            unawaited(session.handleInterruption('系统即将休眠'));
          case PlatformInterruption.locked:
          case PlatformInterruption.backgrounded:
            unawaited(preview.stop());
            // A hidden or locked screen does not change playback membership.
            break;
        }
      });
      if (!mounted) {
        await _events?.cancel();
        await mediaPublisher?.close();
        await preview.close();
        await session.shutdown();
        await library.close();
        await platform.dispose();
        repository.close();
        return;
      }
      setState(() {
        _library = library;
        _preview = preview;
        _session = session;
        _preferences = Preferences(repository);
        _platform = platform;
        _mediaPublisher = mediaPublisher;
        _repository = repository;
        _error = null;
      });
    } catch (error, stack) {
      debugPrint('Heming initialization failed: $error\n$stack');
      await _events?.cancel();
      try {
        await openedPublisher?.close();
      } catch (_) {}
      try {
        await openedPreview?.close();
      } catch (_) {}
      try {
        await openedSession?.shutdown();
      } catch (_) {}
      try {
        await openedLibrary?.close();
      } catch (_) {}
      try {
        await openedPlatform?.dispose();
      } catch (_) {}
      openedRepository?.close();
      if (mounted) setState(() => _error = error);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden ||
        state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached) {
      _foreground = false;
      unawaited(_preview?.stop());
    }
    // Android owns a retained FlutterEngine. Detaching its Activity must not
    // destroy the service's native stream, group sockets or shared timeline.
    if (state == AppLifecycleState.detached && !Platform.isAndroid) {
      unawaited(_shutdown());
    }
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      unawaited(_session?.restartDiscovery());
    }
  }

  Future<void> _shutdown() => _cleanup ??= () async {
    try {
      await _events?.cancel();
    } finally {
      try {
        await _mediaPublisher?.close();
      } finally {
        try {
          await _preview?.close();
        } finally {
          try {
            await _session?.shutdown();
          } finally {
            try {
              await _library?.close();
            } finally {
              try {
                await _platform?.dispose();
              } finally {
                _repository?.close();
              }
            }
          }
        }
      }
    }
  }();

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _preferences?.dispose();
    unawaited(_shutdown());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_session != null && _library != null && _preferences != null) {
      return HemingApp(
        session: _session!,
        library: _library!,
        preferences: _preferences!,
        preview: _preview,
      );
    }
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: '和鸣',
      theme: hemingTheme(Brightness.light),
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(28),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 460),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(
                    Icons.graphic_eq,
                    size: 48,
                    color: Color(0xff25664c),
                  ),
                  const SizedBox(height: 24),
                  const Text(
                    '和鸣',
                    style: TextStyle(fontSize: 26, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 18),
                  if (_error == null) ...[
                    const SizedBox.square(
                      dimension: 22,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(height: 14),
                    const Text('正在准备本机资源与连接…'),
                  ] else ...[
                    const Text(
                      '暂时无法启动',
                      style: TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 12),
                    SelectableText(
                      _error.toString(),
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: 20),
                    FilledButton(
                      onPressed: () {
                        setState(() => _error = null);
                        unawaited(_initialize());
                      },
                      child: const Text('重试'),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
