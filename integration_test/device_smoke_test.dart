import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming_audio/heming_audio.dart';
import 'package:heming_platform/heming_platform.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';
import 'media_fixture.dart';

Uint8List pulseWav({int seconds = 7}) {
  const rate = 48000;
  final frames = rate * seconds;
  final data = ByteData(44 + frames * 4);
  void tag(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      data.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, 36 + frames * 4, Endian.little);
  tag(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, rate, Endian.little);
  data.setUint32(28, rate * 4, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, frames * 4, Endian.little);
  for (var frame = 0; frame < frames; frame++) {
    final value = frame % rate < 2400
        ? (sin(frame * 2 * pi * 660 / rate) * 3200).round()
        : 0;
    data.setInt16(44 + frame * 4, value, Endian.little);
    data.setInt16(46 + frame * 4, value, Endian.little);
  }
  return data.buffer.asUint8List();
}

// Keep fixture allocation bounded on ARM32: the long reverse-direction test
// writes one second of zero PCM at a time rather than retaining the whole WAV.
Future<void> writeSilentWav(File file, {required int seconds}) async {
  const rate = 48000;
  final pcmBytes = seconds * rate * 4;
  final header = ByteData(44);
  void tag(int offset, String text) {
    for (var i = 0; i < text.length; i++) {
      header.setUint8(offset + i, text.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  header.setUint32(4, 36 + pcmBytes, Endian.little);
  tag(8, 'WAVEfmt ');
  header.setUint32(16, 16, Endian.little);
  header.setUint16(20, 1, Endian.little);
  header.setUint16(22, 2, Endian.little);
  header.setUint32(24, rate, Endian.little);
  header.setUint32(28, rate * 4, Endian.little);
  header.setUint16(32, 4, Endian.little);
  header.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  header.setUint32(40, pcmBytes, Endian.little);
  final output = await file.open(mode: FileMode.write);
  try {
    await output.writeFrom(header.buffer.asUint8List());
    final silence = Uint8List(rate * 4);
    for (var second = 0; second < seconds; second++) {
      await output.writeFrom(silence);
    }
  } finally {
    await output.close();
  }
}

Map<String, Object?> audioDiagnostics(AudioStatus status) => {
  'state': status.state.name,
  'frames': status.playedFrames,
  'bufferFrames': status.bufferedFrames,
  'rttUs': status.clockRttMicros,
  'offsetUs': status.clockOffsetMicros,
  'phaseErrorUs': status.phaseErrorMicros,
  'driftPpm': status.driftPpm,
  'hardwareClockValid': status.hardwareClockValid,
  'hardwareRatePpm': status.hardwareRatePpm,
  'outputUnderruns': status.outputUnderruns,
  'outputSampleRate': status.outputSampleRate,
  'callbackFrames': status.callbackFrames,
  'error': status.error,
};

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'OS media extraction, canonical FLAC, native scheduling and stop',
    (tester) async {
      await tester.runAsync(() async {
        final dir = await Directory(
          '${(await getTemporaryDirectory()).path}/heming-smoke',
        ).create(recursive: true);
        final unique = DateTime.now().microsecondsSinceEpoch;
        final source = File('${dir.path}/source-$unique.m4a');
        final wav = File('${dir.path}/extracted-$unique.wav');
        final flac = File('${dir.path}/playable-$unique.flac');
        final pulse = File('${dir.path}/pulse-$unique.wav');
        final pulseFlac = File('${dir.path}/pulse-$unique.flac');
        final platform = HemingPlatform();
        final engine = NativeAudioEngine();
        try {
          final original = base64Decode(aacFixture);
          await source.writeAsBytes(original);
          final metadata = await platform.inspectMedia(source.path);
          expect(metadata['sampleRate'], 44100);
          await platform.extractAudio(source.path, wav.path);
          final conversion = NativeMedia.convert(wav.path, flac.path);
          await conversion.done;
          final profile = await NativeMedia.probe(
            flac.path,
            verifyDecode: true,
          );
          expect(profile.isCanonical && profile.verified, isTrue);
          expect(await source.readAsBytes(), original);
          await pulse.writeAsBytes(pulseWav());
          await NativeMedia.convert(pulse.path, pulseFlac.path).done;
          await platform.setPlaybackActive(true);
          expect(await platform.acquireAudioFocus(), isTrue);
          engine.setOutput(volume: 0, muted: true);
          await engine.prepareLocal(
            path: pulseFlac.path,
            sessionId: 'smoke-session',
            taskId: 'smoke-task',
          );
          expect(engine.status.state, AudioState.ready);
          expect(engine.status.bufferedFrames, greaterThanOrEqualTo(239000));
          engine.scheduleStart(NativeAudioEngine.monotonicMicros() + 600000);
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          expect(engine.status.state, AudioState.playing);
          expect(engine.status.playedFrames, greaterThan(10000));
          // ignore: avoid_print
          print('LOCAL_RESULT ${jsonEncode(audioDiagnostics(engine.status))}');
          await engine.stop();
          expect(engine.status.state, AudioState.idle);
          expect(engine.status.bufferedFrames, 0);
        } finally {
          await engine.dispose();
          await platform.dispose();
          for (final file in [source, wav, flac, pulse, pulseFlac]) {
            if (await file.exists()) await file.delete();
          }
        }
      });
    },
  );

  const host = String.fromEnvironment('HEMING_TEST_HOST');
  const streamSeconds = int.fromEnvironment(
    'HEMING_TEST_STREAM_SECONDS',
    defaultValue: 3,
  );
  const reverseSeconds = int.fromEnvironment(
    'HEMING_TEST_REVERSE_SECONDS',
    defaultValue: 120,
  );
  testWidgets(
    'sustained bidirectional native LAN stream',
    (tester) async {
      await tester.runAsync(() async {
        expect(streamSeconds, inInclusiveRange(3, 1800));
        expect(reverseSeconds, inInclusiveRange(120, 1800));
        final http = HttpClient()
          ..connectionTimeout = const Duration(seconds: 10);
        final temporary = await getTemporaryDirectory();
        final reverseId = DateTime.now().microsecondsSinceEpoch;
        final reverseWav = File('${temporary.path}/reverse-$reverseId.wav');
        final reverseFlac = File('${temporary.path}/reverse-$reverseId.flac');
        Future<Map<String, dynamic>> command(String route) async {
          return (() async {
            final request = await http.getUrl(
              Uri.parse('http://$host:19846/$route'),
            );
            final response = await request.close();
            final body = await utf8.decoder.bind(response).join();
            expect(response.statusCode, HttpStatus.ok, reason: '$route: $body');
            return jsonDecode(body) as Map<String, dynamic>;
          })().timeout(const Duration(seconds: 30));
        }

        final engine = NativeAudioEngine();
        final platform = HemingPlatform();
        try {
          final config = await command('config');
          await platform.setPlaybackActive(true);
          expect(await platform.acquireAudioFocus(), isTrue);
          engine.setOutput(volume: 0, muted: true);
          await engine.prepareRemote(
            host: host,
            port: config['port'] as int,
            sessionId: config['session'] as String,
            taskId: config['task'] as String,
          );
          expect(engine.status.state, AudioState.ready);
          final start = await command('start');
          engine.scheduleStart(start['startUs'] as int);
          final streamWatch = Stopwatch()..start();
          // This is a software stability run with muted hardware output. Values
          // sampled over HTTP are not simultaneous speaker measurements.
          while (streamWatch.elapsed.inSeconds < streamSeconds) {
            await Future<void>.delayed(const Duration(seconds: 1));
            if (streamWatch.elapsed.inSeconds < 3) continue;
            final sample = engine.status;
            expect(sample.state, AudioState.playing, reason: sample.error);
            if (streamWatch.elapsed.inSeconds % 30 == 0) {
              // ignore: avoid_print
              print(
                'LAN_SAMPLE ${jsonEncode({'elapsedSeconds': streamWatch.elapsed.inSeconds, 'android': audioDiagnostics(sample), 'windows': await command('status')})}',
              );
            }
          }
          final local = engine.status;
          final remote = await command('status');
          expect(local.state, AudioState.playing);
          expect(local.playedFrames, greaterThan(40000));
          expect(remote['state'], 'playing');
          // Software positions are diagnostic data, not a measured speaker offset.
          // ignore: avoid_print
          print(
            'LAN_RESULT ${jsonEncode({'elapsedSeconds': streamWatch.elapsed.inSeconds, 'android': audioDiagnostics(local), 'windows': remote})}',
          );
          await command('reset');
          await engine.stop();
          expect(engine.status.bufferedFrames, 0);

          await writeSilentWav(reverseWav, seconds: reverseSeconds + 15);
          await NativeMedia.convert(reverseWav.path, reverseFlac.path).done;
          await reverseWav.delete();
          final reversePrepareWatch = Stopwatch()..start();
          await engine.prepareLocal(
            path: reverseFlac.path,
            sessionId: 'heming-lan-reverse-session',
            taskId: 'heming-lan-reverse-task',
          );
          expect(
            (await command('reverse?port=${engine.audioPort}'))['ready'],
            true,
          );
          reversePrepareWatch.stop();
          final reverseStart = NativeAudioEngine.monotonicMicros() + 1500000;
          await command('reverse_start?startUs=$reverseStart');
          engine.scheduleStart(reverseStart);
          // Start the sustained window only after the common scheduled start.
          // The former three-second check could pass from five seconds of
          // prebuffer even when no further PCM arrived from Android.
          final untilStart = reverseStart - NativeAudioEngine.monotonicMicros();
          if (untilStart > 0) {
            await Future<void>.delayed(Duration(microseconds: untilStart));
          }
          final reverseWatch = Stopwatch()..start();
          var minimumAndroidBuffer = 48000 * 5;
          var minimumWindowsBuffer = 48000 * 5;
          var maximumStatusRoundTripMs = 0;
          var previousAndroidFrames = 0;
          var previousWindowsFrames = 0;
          var reverseSamples = 0;
          var nextLogSecond = 30;
          AudioStatus reverseLocal = engine.status;
          Map<String, dynamic> reverseRemote = {};
          while (reverseWatch.elapsed.inSeconds < reverseSeconds) {
            await Future<void>.delayed(const Duration(seconds: 1));
            final statusWatch = Stopwatch()..start();
            reverseRemote = await command('status');
            statusWatch.stop();
            maximumStatusRoundTripMs = max(
              maximumStatusRoundTripMs,
              statusWatch.elapsedMilliseconds,
            );
            reverseLocal = engine.status;
            final windowsFrames = reverseRemote['frames'] as int;
            final windowsBuffer = reverseRemote['bufferFrames'] as int;
            minimumAndroidBuffer = min(
              minimumAndroidBuffer,
              reverseLocal.bufferedFrames,
            );
            minimumWindowsBuffer = min(minimumWindowsBuffer, windowsBuffer);
            reverseSamples++;
            final sample = {
              'elapsedSeconds': reverseWatch.elapsed.inSeconds,
              'android': audioDiagnostics(reverseLocal),
              'windows': reverseRemote,
              'minimumAndroidBufferFrames': minimumAndroidBuffer,
              'minimumWindowsBufferFrames': minimumWindowsBuffer,
            };
            final unhealthy =
                reverseLocal.state != AudioState.playing ||
                reverseRemote['state'] != 'playing' ||
                reverseLocal.bufferedFrames <= 0 ||
                windowsBuffer <= 0 ||
                reverseLocal.playedFrames <= previousAndroidFrames ||
                windowsFrames <= previousWindowsFrames;
            if (reverseSamples == 1 ||
                reverseWatch.elapsed.inSeconds >= nextLogSecond ||
                unhealthy) {
              // ignore: avoid_print
              print('LAN_REVERSE_SAMPLE ${jsonEncode(sample)}');
              nextLogSecond = (reverseWatch.elapsed.inSeconds ~/ 30 + 1) * 30;
            }
            final reason = jsonEncode(sample);
            expect(reverseLocal.state, AudioState.playing, reason: reason);
            expect(reverseRemote['state'], 'playing', reason: reason);
            expect(reverseLocal.bufferedFrames, greaterThan(0), reason: reason);
            expect(windowsBuffer, greaterThan(0), reason: reason);
            expect(
              reverseLocal.playedFrames,
              greaterThan(previousAndroidFrames),
              reason: reason,
            );
            expect(
              windowsFrames,
              greaterThan(previousWindowsFrames),
              reason: reason,
            );
            previousAndroidFrames = reverseLocal.playedFrames;
            previousWindowsFrames = windowsFrames;
          }
          expect(
            reverseRemote['frames'] as int,
            greaterThan((reverseSeconds - 1) * 48000),
          );
          // ignore: avoid_print
          print(
            'LAN_REVERSE_RESULT ${jsonEncode({'elapsedSeconds': reverseWatch.elapsed.inSeconds, 'requestedSeconds': reverseSeconds, 'samples': reverseSamples, 'prepareMs': reversePrepareWatch.elapsedMilliseconds, 'minimumAndroidBufferFrames': minimumAndroidBuffer, 'minimumWindowsBufferFrames': minimumWindowsBuffer, 'maximumStatusRoundTripMs': maximumStatusRoundTripMs, 'android': audioDiagnostics(reverseLocal), 'windows': reverseRemote})}',
          );
          await command('stop');
          await engine.stop();
          expect(engine.status.bufferedFrames, 0);
        } finally {
          // Also close the developer host when an assertion fails midway.
          try {
            await command('stop').timeout(const Duration(seconds: 3));
          } catch (_) {}
          await engine.dispose();
          await platform.dispose();
          http.close(force: true);
          for (final file in [reverseWav, reverseFlac]) {
            if (await file.exists()) await file.delete();
          }
        }
      });
    },
    skip: host.isEmpty,
    timeout: Timeout(Duration(seconds: streamSeconds + reverseSeconds + 180)),
  );
}
