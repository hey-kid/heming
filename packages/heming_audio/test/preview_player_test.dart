import 'dart:async';
import 'dart:io';

import 'package:heming_audio/heming_audio.dart';
import 'package:test/test.dart';

import 'media_test.dart' show wav;

Future<void> waitForState(
  NativePreviewPlayer player,
  PreviewAudioState state,
) async {
  if (player.status.state == state) return;
  await player.statuses
      .firstWhere((value) => value.state == state)
      .timeout(const Duration(seconds: 5));
}

void main() {
  late Directory directory;
  late String path;
  late NativePreviewPlayer player;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('heming_preview_');
    path = '${directory.path}/本机试听.wav';
    await File(path).writeAsBytes(wav(frames: 44100 * 3));
    player = NativePreviewPlayer()
      ..setVolume(0); // Never emit audible test sound.
  });
  tearDown(() async {
    await player.dispose();
    await directory.delete(recursive: true);
  });

  test('local preview opens paused, resumes, seeks, and completes', () async {
    await player.open(path);
    expect(player.status.state, PreviewAudioState.paused);
    expect(player.status.durationMs, closeTo(3000, 5));
    expect(player.status.positionMs, 0);
    await player.play();
    await Future<void>.delayed(const Duration(milliseconds: 240));
    await player.pause();
    final paused = player.status.positionMs;
    expect(paused, greaterThan(0));
    await Future<void>.delayed(const Duration(milliseconds: 160));
    expect(player.status.positionMs, paused);
    await player.seek(1200);
    expect(player.status.positionMs, 1200);
    expect(player.status.state, PreviewAudioState.paused);
    await player.play();
    await player.seek(2800);
    expect(player.status.state, PreviewAudioState.playing);
    await waitForState(player, PreviewAudioState.completed);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    await player.play();
    expect(player.status.positionMs, lessThan(500));
    await player.stop();
    expect(player.status.state, PreviewAudioState.idle);
    expect(player.status.durationMs, 0);
  });

  test(
    'file failure is recoverable and FLAC can be previewed directly',
    () async {
      await expectLater(
        player.open('$path.missing'),
        throwsA(isA<PreviewAudioException>()),
      );
      expect(player.status.state, PreviewAudioState.failed);
      expect(player.status.error, isNotEmpty);
      final flac = '${directory.path}/试听副本.flac';
      await NativeMedia.convert(path, flac).done;
      await player.open(flac);
      expect(player.status.state, PreviewAudioState.paused);
      expect(player.status.error, isNull);
      expect(player.status.durationMs, closeTo(3000, 5));
    },
  );

  test(
    'stop cancels queued starts and a subsequent open remains playable',
    () async {
      for (var i = 0; i < 4; ++i) {
        final opened = player.open(path);
        final started = player.play();
        final stopped = player.stop();
        await Future.wait([opened, started, stopped]);
        expect(player.status.state, PreviewAudioState.idle);
      }
      final opened = player.open(path);
      await Future<void>.delayed(const Duration(milliseconds: 1));
      final stopped = player.stop();
      await Future.wait([opened, stopped]);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(player.status.state, PreviewAudioState.idle);
      await player.open(path);
      final starting = player.play();
      await Future<void>.delayed(const Duration(milliseconds: 1));
      final interrupted = player.stop();
      await Future.wait([starting, interrupted]);
      await Future<void>.delayed(const Duration(milliseconds: 150));
      expect(player.status.state, PreviewAudioState.idle);
      await player.open(path);
      await player.play();
      expect(player.status.state, PreviewAudioState.playing);
      await player.stop();
    },
  );

  test('disposal safely waits for in-flight open and is idempotent', () async {
    final opened = player.open(path);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final disposed = player.dispose();
    await Future.wait([opened, disposed, player.dispose()]);
    expect(() => player.play(), throwsStateError);
  });
}
