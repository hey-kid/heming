import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:heming/session/native_audio_session_port.dart';
import 'package:heming/session/session_controller.dart';
import 'package:heming_audio/heming_audio.dart' as native;
import 'package:integration_test/integration_test.dart';
import 'package:path_provider/path_provider.dart';

Future<void> _waitFor(bool Function() condition, String description) async {
  final watch = Stopwatch()..start();
  while (!condition() && watch.elapsed < const Duration(seconds: 20)) {
    await Future<void>.delayed(const Duration(milliseconds: 25));
  }
  expect(condition(), isTrue, reason: description);
}

Uint8List _silentWav() {
  const frames = 48000 * 3;
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

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
    'real native queue synchronizes modes, navigation and natural EOF across two devices',
    (tester) async {
      await tester.runAsync(() async {
        final temp = await getTemporaryDirectory();
        final dir = await Directory(
          '${temp.path}/heming-queue-smoke-${DateTime.now().microsecondsSinceEpoch}',
        ).create(recursive: true);
        final files = <File>[];
        final tracks = <PlayableTrack>[];
        final masterEngine = native.NativeAudioEngine();
        final followerEngine = native.NativeAudioEngine();
        final master = SessionController(
          audio: NativeAudioSessionPort(engine: masterEngine),
          deviceId: 'queue-native-master',
          deviceName: '队列主控测试',
          enableDiscovery: false,
        );
        final follower = SessionController(
          audio: NativeAudioSessionPort(engine: followerEngine),
          deviceId: 'queue-native-follower',
          deviceName: '队列跟随测试',
          enableDiscovery: false,
        );
        final masterTasks = <(String, int)>[];
        final followerTasks = <(String, int)>[];
        void record(SessionController session, List<(String, int)> tasks) {
          final task = session.taskId;
          if (task != null && (tasks.isEmpty || tasks.last.$1 != task)) {
            tasks.add((task, session.queueIndex));
          }
        }

        master.addListener(() => record(master, masterTasks));
        follower.addListener(() => record(follower, followerTasks));
        final watch = Stopwatch();
        try {
          for (var i = 0; i < 3; i++) {
            final wav = File('${dir.path}/source-$i.wav');
            final flac = File('${dir.path}/playable-$i.flac');
            files.addAll([wav, flac]);
            await wav.writeAsBytes(_silentWav());
            await native.NativeMedia.convert(wav.path, flac.path).done;
            final info = await native.NativeMedia.probe(
              flac.path,
              verifyDecode: true,
            );
            expect(info.isCanonical && info.verified, isTrue);
            expect(info.totalFrames, 144000);
            tracks.add(
              PlayableTrack(
                id: 'queue-song-$i',
                title: '队列静音歌曲 ${i + 1}',
                path: flac.path,
                durationMs: 3000,
              ),
            );
          }
          await master.initialize(port: 0);
          await follower.initialize(port: 0);
          master.setOutput(muted: true);
          follower.setOutput(muted: true);
          await master.createRoom();
          await follower.join('127.0.0.1', port: master.serverPort);
          await _waitFor(
            () => master.pendingJoins.length == 1,
            'master receives actual WebSocket join request',
          );
          master.approveJoin(follower.localDevice.id);
          await _waitFor(() => follower.isConnected, 'follower is accepted');
          final sessionId = master.sessionId;
          Future<void> bothPlaying(
            int expectedIndex, {
            String? previousTask,
          }) async {
            final task = master.taskId;
            expect(task, isNotNull);
            if (previousTask != null) expect(task, isNot(previousTask));
            await _waitFor(
              () =>
                  master.phase == SessionPhase.playing &&
                  follower.phase == SessionPhase.playing &&
                  follower.taskId == task,
              'both native outputs start queue index $expectedIndex: '
              '${master.error} / ${follower.error}',
            );
            expect(master.taskId, task);
            for (final device in [master, follower]) {
              expect(device.sessionId, sessionId);
              expect(device.members.length, 2);
              expect(device.membersLocked, isTrue);
              expect(
                device.queue.map((track) => track.toWire()),
                tracks.map((track) => track.toWire()),
              );
              expect(device.queueIndex, expectedIndex);
              expect(device.currentTrack?.id, tracks[expectedIndex].id);
            }
            for (final engine in [masterEngine, followerEngine]) {
              expect(engine.status.state, native.AudioState.playing);
              expect(engine.status.totalFrames, 144000);
              expect(engine.status.error, isNull);
            }
          }

          watch.start();
          await master.startPlaylist(tracks);
          await bothPlaying(0);
          expect(master.playbackMode, PlaybackMode.sequential);

          final initialTask = master.taskId!;
          master.setPlaybackMode(PlaybackMode.random);
          await _waitFor(
            () =>
                follower.playbackMode == PlaybackMode.random &&
                follower.modeChangePending,
            'mode selection reaches follower without replacing this song',
          );
          expect(master.taskId, initialTask);
          expect(follower.taskId, initialTask);
          expect(master.modeChangePending, isTrue);
          expect(masterTasks.length, 1);
          expect(followerTasks.length, 1);

          await master.nextTrack();
          final randomIndex = master.queueIndex;
          expect(randomIndex, anyOf(1, 2));
          await bothPlaying(randomIndex, previousTask: initialTask);
          expect(master.modeChangePending, isFalse);
          expect(follower.modeChangePending, isFalse);
          final randomTask = master.taskId;

          await master.previousTrack();
          await bothPlaying(0, previousTask: randomTask);
          final previousTask = master.taskId;
          await master.nextTrack();
          await bothPlaying(randomIndex, previousTask: previousTask);

          final historyTask = master.taskId;
          final remainingIndex = randomIndex == 1 ? 2 : 1;
          await master.selectQueueTrack(remainingIndex);
          await bothPlaying(remainingIndex, previousTask: historyTask);

          // Switch back to sequential and explicitly select the first item.
          // The following two transitions must come from real native EOF,
          // without any test-generated completion events or next calls.
          final selectedTask = master.taskId;
          master.setPlaybackMode(PlaybackMode.sequential);
          expect(master.taskId, selectedTask);
          expect(master.modeChangePending, isTrue);
          await master.selectQueueTrack(0);
          await bothPlaying(0, previousTask: selectedTask);
          expect(master.modeChangePending, isFalse);
          expect(follower.modeChangePending, isFalse);
          final naturalStart = masterTasks.length - 1;
          await _waitFor(
            () =>
                master.queueIndex == 1 &&
                follower.queueIndex == 1 &&
                master.taskId == follower.taskId &&
                master.phase == SessionPhase.playing &&
                follower.phase == SessionPhase.playing,
            'the first real native EOF advances both devices to the next song',
          );
          expect(master.members.length, 2);
          expect(follower.members.length, 2);
          await _waitFor(
            () =>
                master.phase == SessionPhase.standby &&
                follower.phase == SessionPhase.standby &&
                masterEngine.status.state == native.AudioState.idle &&
                followerEngine.status.state == native.AudioState.idle,
            'remaining native EOFs finish the queue and stop both engines',
          );
          expect(masterTasks.skip(naturalStart).map((entry) => entry.$2), [
            0,
            1,
            2,
          ]);
          expect(followerTasks, masterTasks);
          expect(
            masterTasks.map((entry) => entry.$1).toSet().length,
            masterTasks.length,
          );
          for (final device in [master, follower]) {
            expect(device.members.length, 2);
            expect(device.sessionId, sessionId);
            expect(device.queue, isEmpty);
            expect(device.currentTrack, isNull);
            expect(device.taskId, isNull);
          }
          expect(masterEngine.status.bufferedFrames, 0);
          expect(followerEngine.status.bufferedFrames, 0);
          // ignore: avoid_print
          print(
            'QUEUE_RESULT tracks=3 fullQueueSynced=true modeDeferred=true '
            'manualSwitches=5 naturalAdvances=2 uniqueTasks=${masterTasks.length} '
            'members=2 bothBuffers=0 elapsedMs=${watch.elapsedMilliseconds}',
          );
        } finally {
          try {
            await follower.shutdown();
          } finally {
            try {
              await master.shutdown();
            } finally {
              for (final file in files) {
                if (await file.exists()) await file.delete();
              }
              await dir.delete();
            }
          }
        }
      });
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );
}
