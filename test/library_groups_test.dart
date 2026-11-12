import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

class GroupMedia implements MediaBackend {
  Completer<void>? inspectionGate;
  Completer<void>? conversionGate;
  final conversionStarted = Completer<void>();

  @override
  Future<AudioMetadata> inspect(
    String path, {
    bool verifyDecode = false,
  }) async {
    await inspectionGate?.future;
    final canonical = p.extension(path) == '.flac';
    return AudioMetadata(
      codec: canonical ? 'flac' : 'mp3',
      sampleRate: canonical ? 48000 : 44100,
      channels: 2,
      bitsPerSample: 16,
      durationMs: 3000,
      verified: canonical && verifyDecode,
    );
  }

  @override
  Future<void> convert(
    String inputPath,
    String outputPath,
    ConversionToken token,
    void Function(double) onProgress,
  ) async {
    conversionStarted.complete();
    await conversionGate?.future;
    token.throwIfCancelled();
    await File(outputPath).writeAsBytes([9, 8, 7]);
    onProgress(1);
  }
}

void main() {
  late Directory root;
  late LibraryRepository repository;
  late LibraryController controller;
  late GroupMedia media;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('heming-groups-test-');
    repository = await LibraryRepository.open(root);
    final source = await File(
      p.join(repository.originals.path, 'source.mp3'),
    ).writeAsBytes([1, 2, 3]);
    for (var i = 0; i < 3; i++) {
      repository.save(
        LibraryItem(
          id: 'track-$i',
          title: 'Track $i',
          originalPath: source.path,
          originalName: 'source.mp3',
          status: LibraryStatus.needsConversion,
          importedAt: DateTime(2026, 11, 10, 12, i),
        ),
      );
    }
    media = GroupMedia();
    controller = LibraryController(repository: repository, media: media);
    await controller.initialize();
  });

  tearDown(() async {
    await controller.close();
    repository.close();
    await root.delete(recursive: true);
  });

  test(
    'old library database upgrades without changing media or settings',
    () async {
      final legacyRoot = await Directory.systemTemp.createTemp(
        'heming-old-library-',
      );
      try {
        await Directory(p.join(legacyRoot.path, 'database')).create();
        final original = await File(
          p.join(legacyRoot.path, 'old.flac'),
        ).writeAsBytes([1, 4, 9]);
        final database = sqlite3.open(
          p.join(legacyRoot.path, 'database', 'heming.sqlite'),
        );
        database.execute(
          'CREATE TABLE library (id TEXT PRIMARY KEY, imported_at TEXT NOT NULL, data TEXT NOT NULL)',
        );
        database.execute(
          'CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)',
        );
        database.execute('INSERT INTO settings VALUES (?, ?)', [
          'deviceName',
          '客厅',
        ]);
        final legacy = controller.items.first.toJson()
          ..remove('groupId')
          ..remove('groupOrder')
          ..['originalPath'] = original.path;
        database.execute('INSERT INTO library VALUES (?, ?, ?)', [
          legacy['id'],
          legacy['importedAt'],
          jsonEncode(legacy),
        ]);
        database.close();
        final upgraded = await LibraryRepository.open(legacyRoot);
        try {
          expect(upgraded.loadItems().single.groupId, isNull);
          expect(upgraded.loadItems().single.groupOrder, 0);
          expect(upgraded.loadGroups(), isEmpty);
          expect(upgraded.setting('deviceName'), '客厅');
          expect(await original.readAsBytes(), [1, 4, 9]);
        } finally {
          upgraded.close();
        }
      } finally {
        await legacyRoot.delete(recursive: true);
      }
    },
  );

  test(
    'bulk move and reorder persist independently of library import order',
    () {
      final first = controller.createGroup('  晚间音乐  ');
      final second = controller.createGroup('工作');
      expect(first.name, '晚间音乐');
      controller.moveItemsToGroup(['track-0', 'track-2', 'track-1'], first.id);
      final snapshot = controller.itemsInGroup(first.id);
      controller.moveItemInGroup('track-1', -1);
      expect(controller.itemsInGroup(first.id).map((item) => item.id), [
        'track-0',
        'track-1',
        'track-2',
      ]);
      // Snapshots used to start playback do not change after a library edit.
      expect(snapshot.map((item) => item.id), [
        'track-0',
        'track-2',
        'track-1',
      ]);
      controller.moveItemsToGroup(['track-1'], second.id);
      controller.moveItemsToGroup(['track-0'], second.id);
      expect(controller.itemsInGroup(second.id).map((item) => item.id), [
        'track-1',
        'track-0',
      ]);
      controller.renameGroup(second.id, '专注');
      expect(repository.loadGroups().last.name, '专注');
      final persisted =
          repository
              .loadItems()
              .where((item) => item.groupId == second.id)
              .toList()
            ..sort((a, b) => a.groupOrder.compareTo(b.groupOrder));
      expect(persisted.map((item) => item.id), ['track-1', 'track-0']);
      expect(() => controller.createGroup('专注'), throwsFormatException);
      expect(
        () => controller.renameGroup(second.id, ' '),
        throwsFormatException,
      );
    },
  );

  test(
    'deleting a group only unassigns members and preserves all media files',
    () async {
      final group = controller.createGroup('睡眠');
      controller.moveItemsToGroup(
        controller.items.map((item) => item.id),
        group.id,
      );
      final originalPaths = controller.items
          .map((item) => item.originalPath)
          .toSet();
      final extraCopy = await File(
        p.join(repository.playable.path, 'kept.flac'),
      ).writeAsBytes([9, 8, 7]);
      controller.deleteGroup(group.id);
      expect(controller.groups, isEmpty);
      expect(repository.loadGroups(), isEmpty);
      expect(controller.itemsInGroup(null).length, 3);
      expect(
        repository.loadItems().every((item) => item.groupId == null),
        isTrue,
      );
      for (final path in originalPaths) {
        expect(await File(path).readAsBytes(), [1, 2, 3]);
      }
      expect(await extraCopy.readAsBytes(), [9, 8, 7]);
    },
  );

  test('inspection keeps newer assignments and ordering', () async {
    final group = controller.createGroup('音乐');
    media.inspectionGate = Completer<void>();
    final inspecting = controller.inspectItem('track-0');
    controller.moveItemsToGroup(['track-1', 'track-0'], group.id);
    controller.moveItemInGroup('track-0', -1);
    media.inspectionGate!.complete();
    await inspecting;
    expect(controller.itemsInGroup(group.id).map((item) => item.id), [
      'track-0',
      'track-1',
    ]);
    expect(
      repository.loadItems().firstWhere((item) => item.id == 'track-0').groupId,
      group.id,
    );
  });

  test('conversion completion cannot restore a deleted group', () async {
    final group = controller.createGroup('待处理');
    controller.moveItemsToGroup(['track-0'], group.id);
    media.conversionGate = Completer<void>();
    controller.requestConversion('track-0');
    await media.conversionStarted.future;
    controller.deleteGroup(group.id);
    final finished = Completer<void>();
    void check() {
      if (controller.activeConversionId == null &&
          controller.items.any(
            (item) => item.id == 'track-0' && item.isPlayable,
          ) &&
          !finished.isCompleted) {
        finished.complete();
      }
    }

    controller.addListener(check);
    media.conversionGate!.complete();
    await finished.future.timeout(const Duration(seconds: 5));
    controller.removeListener(check);
    final ready = repository.loadItems().firstWhere(
      (item) => item.id == 'track-0',
    );
    expect(ready.groupId, isNull);
    expect(ready.groupOrder, 0);
    expect(ready.isPlayable, isTrue);
    expect(await File(ready.originalPath).readAsBytes(), [1, 2, 3]);
  });
}
