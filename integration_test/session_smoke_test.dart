import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heming/session/native_audio_session_port.dart';
import 'package:heming/session/session_controller.dart';
import 'package:heming_audio/heming_audio.dart' as native;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

Future<void> waitFor(bool Function() condition, String description) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < const Duration(seconds: 15)) {
    await Future<void>.delayed(const Duration(milliseconds: 30));
  }
  expect(condition(), isTrue, reason: description);
}

Uint8List silentWav({int seconds = 8}) {
  final frames = 48000 * seconds;
  final bytes = ByteData(44 + frames * 4);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      bytes.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  bytes.setUint32(4, 36 + frames * 4, Endian.little);
  tag(8, 'WAVEfmt ');
  bytes.setUint32(16, 16, Endian.little);
  bytes.setUint16(20, 1, Endian.little);
  bytes.setUint16(22, 2, Endian.little);
  bytes.setUint32(24, 48000, Endian.little);
  bytes.setUint32(28, 192000, Endian.little);
  bytes.setUint16(32, 4, Endian.little);
  bytes.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  bytes.setUint32(40, frames * 4, Endian.little);
  return bytes.buffer.asUint8List();
}

/// Records actual native stop results without replacing or delaying the normal
/// adapter operations. Each switch must discard the preceding task's PCM.
class AuditedNativePort extends NativeAudioSessionPort {
  AuditedNativePort(this.engine) : super(engine: engine);
  final native.NativeAudioEngine engine;
  final List<native.AudioStatus> stops = [];

  @override
  Future<void> stop() async {
    await super.stop();
    stops.add(engine.status);
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('real native audio with WebSocket group and master handover', (
    tester,
  ) async {
    await tester.runAsync(() async {
      final temp = await getTemporaryDirectory();
      final dir = await Directory(
        '${temp.path}/heming-session-smoke-${DateTime.now().microsecondsSinceEpoch}',
      ).create(recursive: true);
      final wav = File('${dir.path}/source.wav');
      final flac = File('${dir.path}/playable.flac');
      final firstEngine = native.NativeAudioEngine();
      final secondEngine = native.NativeAudioEngine();
      final first = SessionController(
        audio: NativeAudioSessionPort(engine: firstEngine),
        deviceId: 'native-first',
        deviceName: '本机主控测试',
        enableDiscovery: false,
      );
      final second = SessionController(
        audio: NativeAudioSessionPort(engine: secondEngine),
        deviceId: 'native-second',
        deviceName: '本机跟随测试',
        enableDiscovery: false,
      );
      try {
        await wav.writeAsBytes(silentWav());
        await native.NativeMedia.convert(wav.path, flac.path).done;
        final info = await native.NativeMedia.probe(
          flac.path,
          verifyDecode: true,
        );
        expect(info.isCanonical && info.verified, isTrue);
        final track = PlayableTrack(
          id: 'native-fixture',
          title: '静音集成测试',
          path: flac.path,
          durationMs: 8000,
        );
        await first.initialize(port: 0);
        await second.initialize(port: 0);
        first.setOutput(muted: true);
        second.setOutput(volume: 0.4, channel: AudioChannel.left, muted: true);
        await first.createRoom();
        await second.join('127.0.0.1', port: first.serverPort);
        await waitFor(
          () => first.pendingJoins.length == 1,
          'master receives real join request',
        );
        first.approveJoin(second.localDevice.id);
        await waitFor(() => second.isConnected, 'follower receives acceptance');
        await first.play(track);
        await waitFor(
          () =>
              first.phase == SessionPhase.playing &&
              second.phase == SessionPhase.playing,
          'both hardware outputs reach playing',
        );
        expect(firstEngine.status.playedFrames, greaterThan(0));
        expect(secondEngine.status.playedFrames, greaterThan(0));
        expect(firstEngine.status.bufferedFrames, lessThanOrEqualTo(240000));
        expect(secondEngine.status.bufferedFrames, lessThanOrEqualTo(240000));
        final previousSession = first.sessionId;
        second.requestTakeover();
        await waitFor(
          () => first.takeoverRequester == second.localDevice.id,
          'master receives takeover request',
        );
        await first.approveTakeover();
        await waitFor(
          () =>
              second.isMaster &&
              !second.handoverInProgress &&
              first.masterId == second.localDevice.id,
          'authorized migration completes',
        );
        expect(second.sessionId, isNot(previousSession));
        expect(first.phase, SessionPhase.standby);
        expect(second.phase, SessionPhase.standby);
        expect(firstEngine.status.state, native.AudioState.idle);
        expect(secondEngine.status.state, native.AudioState.idle);
        expect(second.localDevice.channel, AudioChannel.left);
        expect(second.localDevice.volume, 0.4);
        expect(second.localDevice.muted, isTrue);
        await second.play(track);
        await waitFor(
          () =>
              first.phase == SessionPhase.playing &&
              second.phase == SessionPhase.playing,
          'new master starts a new native task',
        );
        await second.endPlayback();
        await waitFor(
          () =>
              first.phase == SessionPhase.standby &&
              firstEngine.status.state == native.AudioState.idle &&
              secondEngine.status.state == native.AudioState.idle,
          'STOP clears both engines',
        );
        expect(firstEngine.status.bufferedFrames, 0);
        expect(secondEngine.status.bufferedFrames, 0);
      } finally {
        await second.shutdown();
        await first.shutdown();
        if (await wav.exists()) await wav.delete();
        if (await flac.exists()) await flac.delete();
        await dir.delete();
      }
    });
  });

  testWidgets(
    'twenty consecutive native resource switches discard both old buffers',
    (tester) async {
      await tester.runAsync(() async {
        final temp = await getTemporaryDirectory();
        final dir = await Directory(
          '${temp.path}/heming-switch-smoke-${DateTime.now().microsecondsSinceEpoch}',
        ).create(recursive: true);
        final files = <File>[];
        final tracks = <PlayableTrack>[];
        final firstEngine = native.NativeAudioEngine();
        final secondEngine = native.NativeAudioEngine();
        final firstPort = AuditedNativePort(firstEngine);
        final secondPort = AuditedNativePort(secondEngine);
        final first = SessionController(
          audio: firstPort,
          deviceId: 'switch-first',
          deviceName: '切换主控测试',
          enableDiscovery: false,
        );
        final second = SessionController(
          audio: secondPort,
          deviceId: 'switch-second',
          deviceName: '切换跟随测试',
          enableDiscovery: false,
        );
        try {
          for (final seconds in [8, 11]) {
            final wav = File('${dir.path}/source-$seconds.wav');
            final flac = File('${dir.path}/playable-$seconds.flac');
            files.addAll([wav, flac]);
            await wav.writeAsBytes(silentWav(seconds: seconds));
            await native.NativeMedia.convert(wav.path, flac.path).done;
            final info = await native.NativeMedia.probe(
              flac.path,
              verifyDecode: true,
            );
            expect(info.isCanonical && info.verified, isTrue);
            expect(info.totalFrames, 48000 * seconds);
            tracks.add(
              PlayableTrack(
                id: 'switch-$seconds',
                title: '$seconds 秒静音切换测试',
                path: flac.path,
                durationMs: seconds * 1000,
              ),
            );
          }
          await first.initialize(port: 0);
          await second.initialize(port: 0);
          first.setOutput(muted: true);
          second.setOutput(muted: true);
          await first.createRoom();
          await second.join('127.0.0.1', port: first.serverPort);
          await waitFor(
            () => first.pendingJoins.length == 1,
            'switch master receives actual join request',
          );
          first.approveJoin(second.localDevice.id);
          await waitFor(() => second.isConnected, 'switch follower accepted');
          final session = first.sessionId;
          final taskIds = <String>{};
          final watch = Stopwatch()..start();
          for (var iteration = 0; iteration <= 20; iteration++) {
            final track = tracks[iteration % tracks.length];
            final previousTask = first.taskId;
            final firstStops = firstPort.stops.length;
            final secondStops = secondPort.stops.length;
            await first.play(track);
            final currentTask = first.taskId;
            expect(currentTask, isNotNull);
            expect(currentTask, isNot(previousTask));
            expect(taskIds.add(currentTask!), isTrue);
            await waitFor(
              () =>
                  first.phase == SessionPhase.playing &&
                  second.phase == SessionPhase.playing &&
                  second.taskId == currentTask,
              'both outputs playing after switch $iteration: '
              '${first.error} / ${second.error}',
            );
            expect(first.sessionId, session);
            expect(second.sessionId, session);
            expect(first.members.length, 2);
            expect(second.members.length, 2);
            expect(first.currentTrack?.id, track.id);
            expect(second.currentTrack?.id, track.id);
            expect(first.membersLocked && second.membersLocked, isTrue);
            for (final states in [
              firstPort.stops.skip(firstStops).toList(),
              secondPort.stops.skip(secondStops).toList(),
            ]) {
              expect(states, isNotEmpty, reason: 'switch must stop old output');
              for (final stopped in states) {
                expect(stopped.state, native.AudioState.idle);
                expect(stopped.bufferedFrames, 0);
                expect(stopped.playedFrames, 0);
              }
            }
            for (final engine in [firstEngine, secondEngine]) {
              final status = engine.status;
              expect(status.state, native.AudioState.playing);
              expect(status.totalFrames, track.durationMs * 48);
              expect(status.playedFrames, inInclusiveRange(1, 96000));
              expect(status.bufferedFrames, inInclusiveRange(1, 240000));
              expect(status.error, isNull);
            }
          }
          await first.endPlayback();
          await waitFor(
            () =>
                first.phase == SessionPhase.standby &&
                second.phase == SessionPhase.standby &&
                firstEngine.status.state == native.AudioState.idle &&
                secondEngine.status.state == native.AudioState.idle,
            'final STOP returns both outputs to standby',
          );
          expect(firstEngine.status.bufferedFrames, 0);
          expect(secondEngine.status.bufferedFrames, 0);
          expect(taskIds.length, 21);
          // ignore: avoid_print
          print(
            'SWITCH_RESULT switches=20 uniqueTasks=${taskIds.length} '
            'elapsedMs=${watch.elapsedMilliseconds} bothBuffers=0',
          );
        } finally {
          await second.shutdown();
          await first.shutdown();
          for (final file in files) {
            if (await file.exists()) await file.delete();
          }
          await dir.delete();
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
