import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/media_scan.dart';
import 'package:path/path.dart' as p;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('heming_media_scan');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late Directory root;
  late SystemMediaScanSource source;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('heming-scan-');
    source = SystemMediaScanSource(targetPlatform: TargetPlatform.windows);
    messenger.setMockMethodCallHandler(channel, (call) async => <String>[]);
  });
  tearDown(() async {
    await source.cancel();
    messenger.setMockMethodCallHandler(channel, null);
    await root.delete(recursive: true);
  });

  test(
    'scan lists media in overlapping roots once and excludes managed files',
    () async {
      final nested = await Directory(p.join(root.path, 'music')).create();
      final managed = await Directory(p.join(root.path, 'owned')).create();
      await File(p.join(nested.path, '歌曲.MP3')).writeAsBytes([1]);
      await File(p.join(nested.path, 'movie.MP4')).writeAsBytes([2]);
      await File(p.join(nested.path, 'notes.txt')).writeAsString('no audio');
      await File(p.join(nested.path, 'empty.wav')).create();
      await File(p.join(managed.path, 'copied.flac')).writeAsBytes([3]);
      final entries = await source
          .scan(
            folders: [root.path, nested.path],
            excludedPaths: [managed.path],
          )
          .expand((batch) => batch.entries)
          .toList();
      expect(
        entries.map((e) => e.name),
        unorderedEquals(['歌曲.MP3', 'movie.MP4']),
      );
      expect(
        entries.map((e) => e.category),
        unorderedEquals(['audio', 'video']),
      );
      expect(
        entries.every((e) => e.sizeBytes == 1 && e.modifiedMs > 0),
        isTrue,
      );
      expect(await managed.list().length, 1);
    },
  );

  test('a missing root does not abort a readable root', () async {
    await File(p.join(root.path, 'audio.wav')).writeAsBytes([9]);
    final entries = await source
        .scan(
          folders: [root.path, p.join(root.path, 'missing')],
          excludedPaths: [],
        )
        .expand((batch) => batch.entries)
        .toList();
    expect(entries.single.name, 'audio.wav');
  });

  test(
    'Windows roots come from known folders and cancel stops after a batch',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'defaultFolders');
        return [root.path];
      });
      for (var i = 0; i < 215; i++) {
        await File(p.join(root.path, '$i.wav')).writeAsBytes([1]);
      }
      final batches = <MediaScanBatch>[];
      await for (final batch in source.scan(excludedPaths: [])) {
        batches.add(batch);
        await source.cancel();
      }
      expect(batches, hasLength(1));
      expect(batches.single.entries, hasLength(100));
    },
  );

  test(
    'Android pages preserve partial permission state and remove duplicate IDs',
    () async {
      source = SystemMediaScanSource(targetPlatform: TargetPlatform.android);
      final calls = <String>[];
      Map<String, Object?> entry(int id) => {
        'sourceId': 'content://media/$id',
        'locator': 'content://media/$id',
        'name': '$id.mp4',
        'category': 'video',
        'sizeBytes': 10,
        'modifiedMs': 5,
        'durationMs': 20,
        'folder': 'Movies',
      };
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'scan') {
          expect((call.arguments as Map)['requestPermission'], isTrue);
          return {
            'items': [entry(1)],
            'audioAccess': 'denied',
            'videoAccess': 'partial',
            'scanId': 's',
            'hasMore': true,
          };
        }
        if (call.method == 'scanNext') {
          expect((call.arguments as Map)['scanId'], 's');
          return {
            'items': [entry(1), entry(2)],
            'audioAccess': 'denied',
            'videoAccess': 'partial',
            'hasMore': false,
          };
        }
        return null;
      });
      final batches = await source
          .scan(excludedPaths: [root.path], requestPermission: true)
          .toList();
      expect(calls, ['scan', 'scanNext']);
      expect(batches.map((b) => b.entries.length), [1, 1]);
      expect(
        batches.every(
          (b) => b.videoAccess == 'partial' && b.audioAccess == 'denied',
        ),
        isTrue,
      );
    },
  );

  test(
    'Android cancelled result is discarded and both workers are cancelled',
    () async {
      source = SystemMediaScanSource(targetPlatform: TargetPlatform.android);
      final response = Completer<Object?>();
      final requested = Completer<void>();
      final calls = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call.method);
        if (call.method == 'scan') {
          requested.complete();
          return response.future;
        }
        return null;
      });
      final pending = source.scan(excludedPaths: []).toList();
      await requested.future;
      await source.cancel();
      response.complete({
        'items': [],
        'audioAccess': 'full',
        'videoAccess': 'full',
      });
      expect(await pending, isEmpty);
      expect(calls, containsAll(['cancelScan', 'cancelCopy']));
    },
  );

  test(
    'copy refuses changed source and never overwrites an existing target',
    () async {
      final original = await File(
        p.join(root.path, 'original.mp3'),
      ).writeAsBytes([1, 2, 3]);
      final entry = await MediaScanEntry.fromFile(original.path);
      final existing = await File(
        p.join(root.path, 'exists.mp3'),
      ).writeAsBytes([9]);
      await expectLater(
        source.copyTo(entry, existing.path),
        throwsA(isA<FileSystemException>()),
      );
      expect(await existing.readAsBytes(), [9]);
      await original.writeAsBytes([4, 5, 6, 7]);
      final destination = p.join(root.path, 'new.mp3');
      await expectLater(
        source.copyTo(entry, destination),
        throwsA(isA<FileSystemException>()),
      );
      expect(await File(destination).exists(), isFalse);
    },
  );

  test('copy creates an independent byte-for-byte file', () async {
    final original = await File(
      p.join(root.path, 'original.mp3'),
    ).writeAsBytes([1, 2, 3]);
    final entry = await MediaScanEntry.fromFile(original.path);
    final destination = File(p.join(root.path, 'new.mp3'));
    await source.copyTo(entry, destination.path);
    await original.delete();
    expect(await destination.readAsBytes(), [1, 2, 3]);
  });
}
