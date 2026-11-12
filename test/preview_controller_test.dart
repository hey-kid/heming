import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/preview/preview_controller.dart';

class FakePreviewAudio implements PreviewAudioPort {
  final events = StreamController<PreviewStatus>.broadcast(sync: true);
  final opened = <String>[];
  final broken = <String>{};
  Completer<void>? opening, starting, seeking;
  int plays = 0, stops = 0;
  int epoch = 0;
  bool failPlay = false,
      failPause = false,
      failSeek = false,
      failStop = false,
      failVolume = false;
  double volume = 1;
  bool disposed = false;
  @override
  PreviewStatus status = const PreviewStatus(PreviewState.idle);
  @override
  Stream<PreviewStatus> get statuses => events.stream;
  void emit(PreviewState state, {int? position, String? error}) {
    status = PreviewStatus(
      state,
      positionMs: position ?? status.positionMs,
      durationMs: 10000,
      error: error,
    );
    events.add(status);
  }

  @override
  Future<void> open(String path) async {
    opened.add(path);
    await opening?.future;
    if (broken.contains(path)) throw StateError('unsupported');
    emit(PreviewState.paused, position: 0);
  }

  @override
  Future<void> play() async {
    final current = epoch;
    await starting?.future;
    if (current != epoch) return;
    if (failPlay) throw StateError('start failed');
    plays++;
    emit(PreviewState.playing);
  }

  @override
  Future<void> pause() async {
    if (failPause) throw StateError('pause failed');
    emit(PreviewState.paused);
  }

  @override
  Future<void> seek(int positionMs) async {
    final current = epoch;
    await seeking?.future;
    if (current != epoch) return;
    if (failSeek) throw StateError('seek failed');
    emit(status.state, position: positionMs);
  }

  @override
  Future<void> stop() async {
    stops++;
    epoch++;
    if (failStop) throw StateError('stop failed');
    // Match native asynchronous status delivery and avoid reentrant broadcasts.
    await Future<void>.value();
    emit(PreviewState.idle, position: 0);
  }

  @override
  void setVolume(double value) {
    if (failVolume) throw StateError('volume failed');
    volume = value;
  }

  @override
  Future<void> dispose() async {
    disposed = true;
    await events.close();
  }
}

LibraryItem item(String id, {String? playable}) => LibraryItem(
  id: id,
  title: id,
  originalPath: '$id.mp3',
  originalName: '$id.mp3',
  playablePath: playable,
  status: LibraryStatus.needsConversion,
  importedAt: DateTime(2026),
);

void main() {
  late FakePreviewAudio audio;
  late PreviewController preview;
  late bool allowed, focusAvailable, releaseFails;
  late int acquired, released;
  setUp(() {
    audio = FakePreviewAudio();
    allowed = focusAvailable = true;
    releaseFails = false;
    acquired = released = 0;
    preview = PreviewController(
      audio: audio,
      canPlay: () => allowed,
      acquireFocus: () async {
        acquired++;
        return focusAvailable;
      },
      releaseFocus: () async {
        released++;
        if (releaseFails) throw StateError('focus release failed');
      },
    );
  });
  tearDown(() async => preview.close());

  test(
    'unconverted originals preview with pause, bounded seek and cleanup',
    () async {
      await preview.play(item('one'));
      expect(audio.opened, ['one.mp3']);
      expect(preview.state, PreviewState.playing);
      expect(preview.itemId, 'one');
      await preview.togglePause();
      expect(preview.state, PreviewState.paused);
      await preview.seek(20000);
      expect(preview.positionMs, 10000);
      await preview.togglePause();
      expect(preview.state, PreviewState.playing);
      await preview.stop();
      expect(preview.isActive, false);
      expect(preview.state, PreviewState.idle);
      expect(released, greaterThan(0));
    },
  );

  test('joined room disallows preview before acquiring focus', () async {
    allowed = false;
    await preview.play(item('one'));
    expect(audio.opened, isEmpty);
    expect(acquired, 0);
    expect(preview.isActive, false);
  });

  test('rapid replacement cancels old open before output starts', () async {
    final pending = audio.opening = Completer<void>();
    final first = preview.play(item('one'));
    await Future<void>.delayed(Duration.zero);
    expect(audio.opened, ['one.mp3']);
    final second = preview.play(item('two'));
    audio.opening = null;
    pending.complete();
    await Future.wait([first, second]);
    expect(audio.plays, 1);
    expect(preview.itemId, 'two');
    expect(preview.state, PreviewState.playing);
  });

  test(
    'leaving library while preparing prevents late playback and clears focus',
    () async {
      final pending = audio.opening = Completer<void>();
      final first = preview.play(item('one'));
      await Future<void>.delayed(Duration.zero);
      final stopped = preview.stop();
      allowed = false;
      pending.complete();
      await Future.wait([first, stopped]);
      expect(audio.plays, 0);
      expect(preview.state, PreviewState.idle);
      expect(preview.itemId, null);
      audio.emit(PreviewState.playing);
      expect(preview.state, PreviewState.idle);
      expect(released, greaterThanOrEqualTo(2));
    },
  );

  test(
    'unsupported original falls back to converted copy without changing library',
    () async {
      audio.broken.add('one.mp3');
      final entry = item('one', playable: 'one.flac');
      await preview.play(entry);
      expect(audio.opened, ['one.mp3', 'one.flac']);
      expect(preview.state, PreviewState.playing);
      expect(entry.status, LibraryStatus.needsConversion);
    },
  );

  test('failure remains inline and can be retried', () async {
    audio.broken.add('one.mp3');
    await preview.play(item('one'));
    expect(preview.state, PreviewState.failed);
    expect(preview.itemId, 'one');
    expect(preview.error, isNotEmpty);
    audio.broken.clear();
    await preview.play(item('one'));
    expect(preview.state, PreviewState.playing);
    expect(preview.error, null);
  });

  test(
    'focus duck restores user volume; loss pauses and gain resumes',
    () async {
      preview.setVolume(.4);
      await preview.play(item('one'));
      preview.setFocusAttenuation(.2);
      expect(audio.volume, closeTo(.08, .001));
      await preview.focusLost();
      expect(preview.state, PreviewState.paused);
      await preview.focusGained();
      expect(preview.state, PreviewState.playing);
      expect(audio.volume, .4);
      await preview.togglePause();
      await preview.focusGained();
      expect(preview.state, PreviewState.paused);
    },
  );

  test('stop during focus acquisition cannot resurrect preview', () async {
    await preview.close();
    audio = FakePreviewAudio();
    final focus = Completer<bool>();
    preview = PreviewController(
      audio: audio,
      canPlay: () => allowed,
      acquireFocus: () => focus.future,
      releaseFocus: () async {
        released++;
      },
    );
    final playing = preview.play(item('one'));
    await Future<void>.delayed(Duration.zero);
    final stopped = preview.stop();
    focus.complete(true);
    await Future.wait([playing, stopped]);
    expect(audio.opened, isEmpty);
    expect(audio.plays, 0);
    expect(preview.isActive, false);
  });

  test(
    'duck received while loading remains applied at playback start',
    () async {
      final pending = audio.opening = Completer<void>();
      preview.setVolume(.5);
      final playing = preview.play(item('one'));
      await Future<void>.delayed(Duration.zero);
      preview.setFocusAttenuation(.2);
      pending.complete();
      await playing;
      expect(preview.state, PreviewState.playing);
      expect(audio.volume, closeTo(.1, .001));
    },
  );

  test(
    'completed preview releases focus and replay acquires it again',
    () async {
      await preview.play(item('one'));
      final before = released;
      audio.emit(PreviewState.completed, position: 10000);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(released, before);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(released, before + 1);
      audio.emit(PreviewState.completed, position: 10000);
      await Future<void>.delayed(Duration.zero);
      expect(released, before + 1);
      final acquisitions = acquired;
      await preview.togglePause();
      expect(acquired, acquisitions + 1);
      expect(preview.state, PreviewState.playing);
    },
  );

  test('gain queued while loading cannot overwrite a later duck', () async {
    final pending = audio.opening = Completer<void>();
    preview.setVolume(.5);
    final playing = preview.play(item('one'));
    await Future<void>.delayed(Duration.zero);
    final gaining = preview.focusGained();
    preview.setFocusAttenuation(.2);
    pending.complete();
    await Future.wait([playing, gaining]);
    expect(audio.volume, closeTo(.1, .001));
    expect(preview.state, PreviewState.playing);
  });

  test(
    'stop interrupts native start before its blocked future completes',
    () async {
      final gate = audio.starting = Completer<void>();
      final playing = preview.play(item('one'));
      await Future<void>.delayed(Duration.zero);
      final previousStops = audio.stops;
      final stopped = preview.stop();
      expect(audio.stops, previousStops + 1);
      expect(preview.itemId, isNull);
      gate.complete();
      await Future.wait([playing, stopped]);
      expect(audio.plays, 0);
      expect(preview.state, PreviewState.idle);
    },
  );

  test(
    'replacement interrupts pending seek and old cleanup leaves new playback alive',
    () async {
      await preview.play(item('one'));
      final gate = audio.seeking = Completer<void>();
      final seeking = preview.seek(5000);
      await Future<void>.delayed(Duration.zero);
      final previousStops = audio.stops;
      final replacement = preview.play(item('two'));
      expect(audio.stops, previousStops + 1);
      gate.complete();
      await Future.wait([seeking, replacement]);
      expect(preview.itemId, 'two');
      expect(preview.state, PreviewState.playing);
      expect(audio.status.state, PreviewState.playing);
    },
  );

  test(
    'native failure closes output and focus but preserves inline retry state',
    () async {
      await preview.play(item('one'));
      final previousStops = audio.stops, previousReleases = released;
      audio.emit(PreviewState.failed, error: '损坏的音频');
      await Future<void>.delayed(Duration.zero);
      expect(audio.stops, previousStops + 1);
      expect(released, previousReleases + 1);
      expect(preview.itemId, 'one');
      expect(preview.state, PreviewState.failed);
      expect(preview.error, '损坏的音频');
      audio.emit(PreviewState.idle);
      expect(preview.state, PreviewState.failed);
      await preview.play(item('one'));
      expect(preview.state, PreviewState.playing);
    },
  );

  test(
    'failed seek and resume each release focus and remain retryable',
    () async {
      await preview.play(item('one'));
      audio.failSeek = true;
      await preview.seek(3000);
      expect(preview.state, PreviewState.failed);
      expect(preview.error, contains('跳转'));
      audio.failSeek = false;
      await preview.play(item('one'));
      await preview.togglePause();
      audio.failPlay = true;
      final previousReleases = released;
      await preview.togglePause();
      expect(released, previousReleases + 1);
      expect(preview.state, PreviewState.failed);
    },
  );

  test(
    'failure during seek is not overwritten by late native completion',
    () async {
      await preview.play(item('one'));
      final gate = audio.seeking = Completer<void>();
      final seeking = preview.seek(3000);
      await Future<void>.delayed(Duration.zero);
      audio.emit(PreviewState.failed, error: '解码已中断');
      gate.complete();
      await seeking;
      await Future<void>.delayed(Duration.zero);
      expect(preview.state, PreviewState.failed);
      expect(preview.error, '解码已中断');
      expect(preview.itemId, 'one');
    },
  );

  test(
    'focus output failure during open cannot restart failed preview',
    () async {
      final gate = audio.opening = Completer<void>();
      final playing = preview.play(item('one'));
      await Future<void>.delayed(Duration.zero);
      audio.failVolume = true;
      preview.setFocusAttenuation(.2);
      gate.complete();
      await playing;
      await Future<void>.delayed(Duration.zero);
      expect(preview.state, PreviewState.failed);
      expect(audio.plays, 0);
      expect(preview.error, contains('音量'));
    },
  );

  test('old completed timer cannot release replacement focus', () async {
    await preview.play(item('one'));
    audio.emit(PreviewState.completed, position: 10000);
    await preview.play(item('two'));
    final previousReleases = released;
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(released, previousReleases);
    expect(preview.itemId, 'two');
    expect(preview.state, PreviewState.playing);
  });

  test(
    'focus event errors are contained and cleanup survives stop and release failures',
    () async {
      await preview.play(item('one'));
      audio.failPause = true;
      await preview.focusLost();
      expect(preview.state, PreviewState.failed);
      audio.failPause = false;
      await preview.play(item('one'));
      await preview.focusLost();
      audio.failPlay = true;
      await preview.focusGained();
      expect(preview.state, PreviewState.failed);
      audio.failStop = true;
      releaseFails = true;
      final previousReleases = released;
      await preview.close();
      expect(released, previousReleases + 1);
      expect(audio.disposed, isTrue);
      expect(audio.events.hasListener, isFalse);
      await preview.focusLost();
      await preview.focusGained();
    },
  );
}
