import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/media_scan.dart';
import 'package:heming/preview/preview_controller.dart';
import 'package:heming/preview/scan_preview_controller.dart';
import 'package:path/path.dart' as p;

import 'preview_controller_test.dart' show FakePreviewAudio, item;

MediaScanEntry entry(String id, {String category = 'audio'}) => MediaScanEntry(
  sourceId: id,
  locator: 'content://media/external/audio/media/$id',
  name: '$id.wav',
  category: category,
  sizeBytes: 8,
  modifiedMs: 1000,
  durationMs: 10000,
);

class _Access implements ScanPreviewAccess {
  _Access(this.audio);
  final FakePreviewAudio audio;
  final prepared = <String>[];
  final released = <String>[];
  final releaseStates = <PreviewState>[];
  final gates = <String, Completer<void>>{};
  final failures = <String>{};
  int cancellations = 0;

  @override
  Future<PreparedPreviewSource> prepare(MediaScanEntry entry) async {
    prepared.add(entry.sourceId);
    await gates[entry.sourceId]?.future;
    if (failures.contains(entry.sourceId)) {
      throw const PreviewSourceFailure('无法读取此音频。');
    }
    return PreparedPreviewSource(
      path: '${entry.sourceId}.wav',
      release: () async {
        released.add(entry.sourceId);
        releaseStates.add(audio.status.state);
      },
    );
  }

  @override
  Future<void> cancel() async {
    cancellations++;
    // Deliberately leave preparation pending to verify late-result disposal.
  }
}

Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FakePreviewAudio audio;
  late PreviewController player;
  late ScanPreviewController scan;
  late _Access access;
  late bool allowed, focus;

  setUp(() {
    allowed = focus = true;
    audio = FakePreviewAudio();
    player = PreviewController(
      audio: audio,
      canPlay: () => allowed,
      acquireFocus: () async => focus,
      releaseFocus: () async {},
    );
    access = _Access(audio);
    scan = ScanPreviewController(player: player, access: access);
  });
  tearDown(() async {
    await scan.close();
    for (final gate in access.gates.values) {
      if (!gate.isCompleted) gate.complete();
    }
    await settle();
    await player.close();
  });

  test(
    'audio preview shares controls and releases after output stops',
    () async {
      await scan.play(entry('one'));
      expect(scan.entry?.sourceId, 'one');
      expect(scan.state, PreviewState.playing);
      expect(scan.durationMs, 10000);
      await scan.togglePause();
      expect(scan.state, PreviewState.paused);
      await scan.seek(4000);
      expect(scan.positionMs, 4000);
      await scan.togglePause();
      expect(scan.state, PreviewState.playing);
      await scan.stop();
      expect(scan.isActive, false);
      expect(access.released, ['one']);
      expect(access.releaseStates, [PreviewState.idle]);
      expect(audio.disposed, false);
    },
  );

  test(
    'shared stop cancels preparation promptly and disposes late result',
    () async {
      final gate = access.gates['one'] = Completer<void>();
      final playing = scan.play(entry('one'));
      await settle();
      expect(scan.state, PreviewState.loading);
      expect(player.isActive, true);
      expect(access.prepared, ['one']);
      await player.stop().timeout(const Duration(seconds: 1));
      await playing;
      expect(scan.entry, isNull);
      expect(access.cancellations, 1);
      expect(audio.opened, isEmpty);
      gate.complete();
      await settle();
      expect(access.released, ['one']);
      expect(audio.plays, 0);
    },
  );

  test(
    'rapid switch never resurrects the first source or releases the new one',
    () async {
      final gate = access.gates['one'] = Completer<void>();
      final first = scan.play(entry('one'));
      await settle();
      await scan.play(entry('two'));
      await first;
      expect(audio.opened, ['two.wav']);
      expect(scan.entry?.sourceId, 'two');
      gate.complete();
      await settle();
      expect(access.released, ['one']);
      expect(scan.state, PreviewState.playing);
      await scan.close();
      expect(access.released, ['one', 'two']);
      expect(audio.disposed, false);
    },
  );

  test(
    'closing scanner leaves an unrelated shared-library preview intact',
    () async {
      await scan.play(entry('one'));
      await player.play(item('library'));
      expect(scan.entry, isNull);
      expect(access.released, ['one']);
      await scan.close();
      expect(player.itemId, 'library');
      expect(player.state, PreviewState.playing);
    },
  );

  test('video and joined-room requests never prepare or decode', () async {
    await scan.play(entry('video', category: 'video'));
    allowed = false;
    await scan.play(entry('one'));
    expect(scan.allowed, false);
    expect(scan.isActive, false);
    expect(access.prepared, isEmpty);
    expect(audio.opened, isEmpty);
  });

  test('denied focus releases prepared audio and permits retry', () async {
    focus = false;
    await scan.play(entry('one'));
    expect(scan.state, PreviewState.failed);
    expect(access.released, ['one']);
    expect(audio.opened, isEmpty);
    focus = true;
    await scan.togglePause();
    expect(scan.state, PreviewState.playing);
    await scan.stop();
    expect(access.released, ['one', 'one']);
  });

  test('preparation failures stay in the preview and can be retried', () async {
    access.failures.add('one');
    await scan.play(entry('one'));
    expect(scan.state, PreviewState.failed);
    expect(scan.error, '无法读取此音频。');
    expect(audio.opened, isEmpty);
    access.failures.clear();
    await scan.togglePause();
    expect(scan.state, PreviewState.playing);
  });

  test(
    'output failure cancels a pending source without late playback',
    () async {
      final gate = access.gates['one'] = Completer<void>();
      final playing = scan.play(entry('one'));
      await settle();
      audio.failVolume = true;
      player.setVolume(0.5);
      await playing;
      expect(scan.state, PreviewState.failed);
      expect(access.cancellations, 1);
      gate.complete();
      await settle();
      expect(access.released, ['one']);
      expect(audio.opened, isEmpty);
    },
  );

  test(
    'Windows preparation uses unchanged original and never deletes it',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'heming-preview-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      final original = await File(
        p.join(root.path, 'original.wav'),
      ).writeAsBytes([1, 2, 3]);
      final candidate = await MediaScanEntry.fromFile(original.path);
      final direct = SystemScanPreviewAccess(platform: TargetPlatform.windows);
      final prepared = await direct.prepare(candidate);
      expect(prepared.path, original.path);
      await prepared.release();
      expect(await original.readAsBytes(), [1, 2, 3]);
      expect(await root.list().length, 1);
      await original.writeAsBytes([4, 5]);
      await expectLater(
        direct.prepare(candidate),
        throwsA(isA<PreviewSourceFailure>()),
      );
    },
  );

  test(
    'Android preview copy is isolated from import and deleted after close',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'heming-preview-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      const channel = MethodChannel('heming-preview-copy-test');
      final methods = <String>[];
      String? copiedPath;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'copyPreviewMedia') {
          final arguments = call.arguments as Map;
          expect(arguments['uri'], entry('one').locator);
          expect(arguments['expectedSize'], 8);
          expect(arguments['expectedModifiedMs'], 1000);
          copiedPath = arguments['destination'] as String;
          await File(copiedPath!).writeAsBytes(List.filled(8, 0));
          return null;
        }
        fail('Unexpected channel method: ${call.method}');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      await scan.close();
      scan = ScanPreviewController(
        player: player,
        access: SystemScanPreviewAccess(
          platform: TargetPlatform.android,
          channel: channel,
          temporaryDirectory: () async => root,
        ),
      );
      await scan.play(entry('one'));
      expect(methods, ['copyPreviewMedia']);
      expect(audio.opened, [copiedPath]);
      expect(await File(copiedPath!).exists(), true);
      await scan.close();
      expect(await root.list().isEmpty, true);
    },
  );

  test(
    'Android cancelled copy cannot revive playback or leave a cache file',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'heming-preview-test-',
      );
      addTearDown(() => root.delete(recursive: true));
      const channel = MethodChannel('heming-preview-cancel-test');
      final copying = Completer<void>(), releaseCopy = Completer<void>();
      final methods = <String>[];
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        if (call.method == 'copyPreviewMedia') {
          copying.complete();
          await releaseCopy.future;
          final destination = (call.arguments as Map)['destination'] as String;
          await File(destination).writeAsBytes(List.filled(8, 0));
          return null;
        }
        if (call.method == 'cancelPreviewCopy') return null;
        fail('Unexpected channel method: ${call.method}');
      });
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
      final native = SystemScanPreviewAccess(
        platform: TargetPlatform.android,
        channel: channel,
        temporaryDirectory: () async => root,
      );
      await scan.close();
      scan = ScanPreviewController(player: player, access: native);
      final playing = scan.play(entry('one'));
      await copying.future;
      await player.stop().timeout(const Duration(seconds: 1));
      await playing;
      expect(methods, ['copyPreviewMedia', 'cancelPreviewCopy']);
      expect(audio.opened, isEmpty);
      releaseCopy.complete();
      // A second preparation waits for the late cancelled copy and its cleanup.
      await expectLater(
        native.prepare(entry('video', category: 'video')),
        throwsA(isA<PreviewSourceFailure>()),
      );
      for (var i = 0; i < 20 && !await root.list().isEmpty; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      expect(await root.list().isEmpty, true);
      expect(audio.plays, 0);
      expect(scan.isActive, false);
    },
  );
}
