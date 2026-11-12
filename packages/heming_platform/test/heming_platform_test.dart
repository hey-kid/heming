import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming_platform/heming_platform.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('heming_platform');
  final calls = <MethodCall>[];
  setUp(() {
    calls.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'acquireAudioFocus') return true;
          if (call.method == 'acquirePreviewAudioFocus') return true;
          if (call.method == 'resumeLocalAudioFocus') return true;
          if (call.method == 'beginNativeOutputPreparation') return 42;
          if (call.method == 'inspectMedia') {
            return {
              'codec': 'audio/mp4a-latm',
              'sampleRate': 44100,
              'channels': 2,
            };
          }
          return null;
        });
  });
  test('inspection does not request extraction or audio focus', () async {
    final platform = HemingPlatform();
    expect((await platform.inspectMedia('original.mp4'))['sampleRate'], 44100);
    expect(calls.map((c) => c.method), ['initialize', 'inspectMedia']);
    await platform.dispose();
  });
  test(
    'Android output preparation carries the token and completion result',
    () async {
      final platform = HemingPlatform(targetPlatform: TargetPlatform.android);
      final token = await platform.beginNativeOutputPreparation();
      expect(token, 42);
      await platform.endNativeOutputPreparation(token, success: true);
      expect(calls.last.method, 'endNativeOutputPreparation');
      expect(calls.last.arguments, {'token': 42, 'success': true});
      await platform.endNativeOutputPreparation(token, success: false);
      expect(calls.last.arguments, {'token': 42, 'success': false});
      expect(await platform.resumeLocalAudioFocus(), isTrue);
      expect(calls.last.method, 'resumeLocalAudioFocus');
      await platform.dispose();
    },
  );
  test('Android-only playback tracking is a no-op on Windows', () async {
    final platform = HemingPlatform(targetPlatform: TargetPlatform.windows);
    expect(await platform.beginNativeOutputPreparation(), isNull);
    await platform.endNativeOutputPreparation(null, success: true);
    expect(await platform.resumeLocalAudioFocus(), isTrue);
    await platform.updateMediaPlayback(MediaPlaybackInfo.idle);
    expect(await platform.acquirePreviewAudioFocus(), isTrue);
    await platform.releasePreviewAudioFocus();
    expect(calls.map((call) => call.method), ['initialize']);
    await platform.dispose();
  });
  test(
    'Android preview requests and releases its own focus without group service or media state',
    () async {
      final platform = HemingPlatform(targetPlatform: TargetPlatform.android);
      expect(await platform.acquirePreviewAudioFocus(), isTrue);
      await platform.releasePreviewAudioFocus();
      expect(calls.map((call) => call.method), [
        'initialize',
        'acquirePreviewAudioFocus',
        'releasePreviewAudioFocus',
      ]);
      // Disposing the platform releases a possible preview lease before the
      // separate group lease; preview release itself must not stop that group.
      await platform.dispose();
      expect(calls.map((call) => call.method).toList().sublist(3), [
        'releasePreviewAudioFocus',
        'releaseAudioFocus',
      ]);
    },
  );
  test(
    'Android preview denial is returned without acquiring group focus as fallback',
    () async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            calls.add(call);
            if (call.method == 'acquirePreviewAudioFocus') return false;
            return null;
          });
      final platform = HemingPlatform(targetPlatform: TargetPlatform.android);
      expect(await platform.acquirePreviewAudioFocus(), isFalse);
      expect(calls.map((call) => call.method), [
        'initialize',
        'acquirePreviewAudioFocus',
      ]);
      await platform.dispose();
    },
  );
  test(
    'Android media status is display-only and carries current metadata',
    () async {
      final platform = HemingPlatform(targetPlatform: TargetPlatform.android);
      const info = MediaPlaybackInfo(
        active: true,
        taskId: 'task-one',
        title: '音乐',
        phase: 'playing',
        durationMs: 120000,
        positionMs: 13000,
        deviceCount: 2,
        isMaster: false,
        outputSuppressed: true,
      );
      await platform.updateMediaPlayback(info);
      expect(calls.map((call) => call.method), [
        'initialize',
        'updateMediaPlayback',
      ]);
      expect(calls.last.arguments, info.toMap());
      await platform.updateMediaPlayback(MediaPlaybackInfo.idle);
      expect(calls.last.arguments, MediaPlaybackInfo.idle.toMap());
      await platform.dispose();
    },
  );
  test('focus and media stop events retain their distinct meanings', () async {
    final platform = HemingPlatform();
    final events = <PlatformInterruption>[];
    final subscription = platform.events.listen(events.add);
    for (final name in [
      'audioFocusDucked',
      'audioFocusLost',
      'audioFocusGained',
      'previewFocusLost',
      'previewFocusDucked',
      'previewFocusGained',
      'stopRequested',
    ]) {
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'heming_platform',
            const StandardMethodCodec().encodeMethodCall(
              MethodCall('onInterruption', name),
            ),
            (_) {},
          );
    }
    await Future<void>.delayed(Duration.zero);
    expect(events, [
      PlatformInterruption.audioFocusDucked,
      PlatformInterruption.audioFocusLost,
      PlatformInterruption.audioFocusGained,
      PlatformInterruption.previewFocusLost,
      PlatformInterruption.previewFocusDucked,
      PlatformInterruption.previewFocusGained,
      PlatformInterruption.stopRequested,
    ]);
    await subscription.cancel();
    await platform.dispose();
  });
  test(
    'extraction retains distinct source and output arguments and supports cancellation',
    () async {
      final platform = HemingPlatform();
      await platform.extractAudio('original.mp4', 'temporary.wav');
      expect(calls.last.arguments, {
        'input': 'original.mp4',
        'output': 'temporary.wav',
      });
      await platform.cancelMediaExtraction();
      expect(calls.last.method, 'cancelMediaExtraction');
      await platform.dispose();
    },
  );
}
