import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum PlatformInterruption {
  locked,
  backgrounded,
  audioFocusDucked,
  audioFocusLost,
  audioFocusGained,
  previewFocusLost,
  previewFocusDucked,
  previewFocusGained,
  stopRequested,
  outputChanged,
  suspending,
}

/// Display-only state for Android's notification and system media surfaces.
/// Publishing this never starts playback or acquires an audio focus lease.
class MediaPlaybackInfo {
  const MediaPlaybackInfo({
    required this.active,
    this.taskId,
    this.title = '',
    this.phase = 'idle',
    this.durationMs = 0,
    this.positionMs = 0,
    this.deviceCount = 0,
    this.isMaster = false,
    this.outputSuppressed = false,
  });

  static const idle = MediaPlaybackInfo(active: false);
  final bool active;
  final String? taskId;
  final String title;
  final String phase;
  final int durationMs;
  final int positionMs;
  final int deviceCount;
  final bool isMaster;
  final bool outputSuppressed;

  Map<String, Object?> toMap() => {
    'active': active,
    'taskId': taskId,
    'title': title,
    'phase': phase,
    'durationMs': durationMs,
    'positionMs': positionMs,
    'deviceCount': deviceCount,
    'isMaster': isMaster,
    'outputSuppressed': outputSuppressed,
  };
}

/// OS events and media codecs only; sound output belongs to heming_audio.
class HemingPlatform {
  static const _channel = MethodChannel('heming_platform');
  final _events = StreamController<PlatformInterruption>.broadcast();
  final bool _isAndroid;
  HemingPlatform({TargetPlatform? targetPlatform})
    : _isAndroid =
          (targetPlatform ?? defaultTargetPlatform) == TargetPlatform.android {
    unawaited(_channel.invokeMethod<void>('initialize'));
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onInterruption') {
        for (final event in PlatformInterruption.values) {
          if (event.name == call.arguments && !_events.isClosed) {
            _events.add(event);
          }
        }
      }
    });
  }
  Stream<PlatformInterruption> get events => _events.stream;
  Future<bool> acquireAudioFocus() async =>
      await _channel.invokeMethod<bool>('acquireAudioFocus') ?? false;
  Future<void> releaseAudioFocus() =>
      _channel.invokeMethod('releaseAudioFocus');

  /// A foreground-only local preview lease, independent of group playback.
  /// This does not start a foreground service or publish media controls.
  Future<bool> acquirePreviewAudioFocus() async => _isAndroid
      ? await _channel.invokeMethod<bool>('acquirePreviewAudioFocus') ?? false
      : true;
  Future<void> releasePreviewAudioFocus() async {
    if (!_isAndroid) return;
    await _channel.invokeMethod<void>('releasePreviewAudioFocus');
  }

  Future<void> setPlaybackActive(bool active) =>
      _channel.invokeMethod('setPlaybackActive', {'active': active});
  Future<void> updateMediaPlayback(MediaPlaybackInfo info) async {
    if (!_isAndroid) return;
    await _channel.invokeMethod<void>('updateMediaPlayback', info.toMap());
  }

  Future<int?> beginNativeOutputPreparation() async => _isAndroid
      ? await _channel.invokeMethod<int>('beginNativeOutputPreparation')
      : null;
  Future<void> endNativeOutputPreparation(
    int? token, {
    required bool success,
  }) async {
    if (!_isAndroid) return;
    await _channel.invokeMethod<void>('endNativeOutputPreparation', {
      'token': token,
      'success': success,
    });
  }

  Future<bool> resumeLocalAudioFocus() async => _isAndroid
      ? await _channel.invokeMethod<bool>('resumeLocalAudioFocus') ?? false
      : true;
  Future<Map<String, dynamic>> inspectMedia(String path) async =>
      Map<String, dynamic>.from(
        await _channel.invokeMapMethod<String, dynamic>('inspectMedia', {
              'path': path,
            }) ??
            {},
      );
  Future<void> extractAudio(String input, String outputWav) => _channel
      .invokeMethod('extractAudio', {'input': input, 'output': outputWav});
  Future<void> cancelMediaExtraction() =>
      _channel.invokeMethod('cancelMediaExtraction');
  Future<void> dispose() async {
    await releasePreviewAudioFocus();
    await releaseAudioFocus();
    _channel.setMethodCallHandler(null);
    await _events.close();
  }
}
