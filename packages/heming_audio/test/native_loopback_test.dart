import 'dart:io';
import 'package:heming_audio/heming_audio.dart';
import 'package:test/test.dart';
import 'media_test.dart' show wav;

void main() {
  test(
    'native PCM loopback survives READY barrier and ends on both outputs',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'heming_loopback_',
      );
      final master = NativeAudioEngine(), follower = NativeAudioEngine();
      master.setOutput(muted: true);
      follower.setOutput(muted: true);
      try {
        final input = File('${directory.path}/source.wav');
        await input.writeAsBytes(wav(frames: 44100 * 6));
        final path = '${directory.path}/playable.flac';
        await NativeMedia.convert(input.path, path).done;
        stdout.writeln('loopback: converted; preparing master');
        await master.prepareLocal(
          path: path,
          sessionId: 'loopback-session',
          taskId: 'track-one',
        );
        expect(master.status.bufferedFrames, 240000);
        stdout.writeln('loopback: master ready; probing rejected handshakes');
        // Invalid handshakes must not exhaust all authenticated member slots.
        for (var i = 0; i < 6; i++) {
          final socket = await Socket.connect('127.0.0.1', master.audioPort);
          socket.add(List.filled(24, 0));
          await socket.flush();
          socket.destroy();
        }
        await follower.prepareRemote(
          host: '127.0.0.1',
          port: master.audioPort,
          sessionId: 'loopback-session',
          taskId: 'track-one',
        );
        expect(follower.status.bufferedFrames, 240000);
        stdout.writeln('loopback: follower ready; holding barrier six seconds');
        await Future<void>.delayed(const Duration(seconds: 6));
        if (Platform.isWindows) {
          final hardware = master.status;
          expect(hardware.hardwareClockSource, 1);
          expect(hardware.hardwarePositionMicros, greaterThan(0));
          expect(hardware.hardwareTimestampMicros, greaterThan(0));
          expect(hardware.hardwareRateWindows, greaterThanOrEqualTo(3));
          stdout.writeln(
            'loopback: IAudioClock ${hardware.hardwareRateWindows} rate windows; ${hardware.hardwareRatePpm.toStringAsFixed(2)} ppm',
          );
        }
        final start = NativeAudioEngine.monotonicMicros() + 500000;
        master.scheduleStart(start);
        follower.scheduleStart(start);
        stdout.writeln('loopback: scheduled');
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(master.status.state, AudioState.playing);
        expect(follower.status.state, AudioState.playing);
        final deadline = DateTime.now().add(const Duration(seconds: 9));
        while (DateTime.now().isBefore(deadline) &&
            (master.status.state != AudioState.completed ||
                follower.status.state != AudioState.completed)) {
          expect(
            master.status.state,
            isNot(AudioState.failed),
            reason: master.status.error,
          );
          expect(
            follower.status.state,
            isNot(AudioState.failed),
            reason: follower.status.error,
          );
          await Future<void>.delayed(const Duration(milliseconds: 50));
        }
        expect(master.status.state, AudioState.completed);
        expect(follower.status.state, AudioState.completed);
        stdout.writeln('loopback: completed; stopping master');
        await master.stop();
        stdout.writeln('loopback: master stopped; stopping follower');
        await follower.stop();
        expect(master.status.state, AudioState.idle);
        expect(follower.status.bufferedFrames, 0);
        expect(
          () => master.scheduleStart(
            NativeAudioEngine.monotonicMicros() + 500000,
          ),
          throwsA(isA<AudioException>()),
        );
      } finally {
        stdout.writeln('loopback: disposing follower');
        await follower.dispose();
        stdout.writeln('loopback: disposing master');
        await master.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 45)),
    skip: Platform.environment['HEMING_AUDIO_DEVICE_TEST'] != '1',
  );
  test(
    'sustained 100ms phase shift stops output with audio still buffered',
    () async {
      final directory = await Directory.systemTemp.createTemp('heming_phase_');
      final engine = NativeAudioEngine()..setOutput(muted: true);
      try {
        final input = File('${directory.path}/source.wav');
        await input.writeAsBytes(wav(frames: 44100 * 4));
        final path = '${directory.path}/playable.flac';
        await NativeMedia.convert(input.path, path).done;
        await engine.prepareLocal(
          path: path,
          sessionId: 'phase-session',
          taskId: 'phase-task',
        );
        engine.scheduleStart(NativeAudioEngine.monotonicMicros() + 500000);
        await Future<void>.delayed(const Duration(milliseconds: 800));
        expect(engine.status.state, AudioState.playing);
        engine.setLatencyCompensationMicros(100000);
        final deadline = DateTime.now().add(const Duration(seconds: 2));
        while (DateTime.now().isBefore(deadline) &&
            engine.status.state != AudioState.failed) {
          await Future<void>.delayed(const Duration(milliseconds: 25));
        }
        final failed = engine.status;
        expect(failed.state, AudioState.failed);
        expect(failed.error, contains('持续失同步'));
        expect(failed.bufferedFrames, greaterThan(0));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(engine.status.playedFrames, failed.playedFrames);
      } finally {
        await engine.dispose();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(seconds: 15)),
    skip: Platform.environment['HEMING_AUDIO_DEVICE_TEST'] != '1',
  );
}
