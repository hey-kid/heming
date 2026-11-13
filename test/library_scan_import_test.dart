import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/data/media_scan.dart';
import 'package:path/path.dart' as p;

class _Media implements MediaBackend {
  bool rejectDecode = false;
  @override
  Future<AudioMetadata> inspect(
    String path, {
    bool verifyDecode = false,
  }) async {
    if (rejectDecode || !await File(path).exists()) {
      throw const FormatException('无法解码');
    }
    return const AudioMetadata(
      codec: 'mp3',
      sampleRate: 44100,
      channels: 2,
      bitsPerSample: 16,
      durationMs: 2000,
    );
  }

  @override
  Future<void> convert(
    String inputPath,
    String outputPath,
    ConversionToken token,
    void Function(double) onProgress,
  ) async => throw UnimplementedError();
}

class _HookSource implements MediaScanSource {
  _HookSource(this.onCopy, {this.onCancel});
  final Future<void> Function(MediaScanEntry, String) onCopy;
  final void Function()? onCancel;
  @override
  Future<void> cancel() async => onCancel?.call();
  @override
  Future<void> copyTo(MediaScanEntry entry, String destination) =>
      onCopy(entry, destination);
  @override
  Stream<MediaScanBatch> scan({
    List<String> folders = const [],
    required List<String> excludedPaths,
    bool requestPermission = false,
  }) => const Stream.empty();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory root;
  late LibraryRepository repository;
  late LibraryController controller;
  late SystemMediaScanSource source;

  Future<MediaScanEntry> make(String name, List<int> bytes) async {
    final file = File(p.join(root.path, name));
    await file.parent.create(recursive: true);
    await file.writeAsBytes(bytes);
    return MediaScanEntry.fromFile(file.path);
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('heming-scan-import-');
    repository = await LibraryRepository.open(
      Directory(p.join(root.path, 'app')),
    );
    controller = LibraryController(repository: repository, media: _Media());
    await controller.initialize();
    source = SystemMediaScanSource(targetPlatform: TargetPlatform.windows);
  });
  tearDown(() async {
    await controller.close();
    repository.close();
    await root.delete(recursive: true);
  });

  test(
    'selected sources are copied independently into a chosen persisted group',
    () async {
      final first = await make('song.mp3', [1, 2, 3]);
      final second = await make('video.mp4', [4, 5, 6]);
      final group = controller.createGroup('收藏');
      final result = await controller.importScanned(
        [first, second],
        source,
        groupId: group.id,
      );
      expect(result.imported, 2);
      expect(result.failed, 0);
      expect(controller.importCompleted, 2);
      expect(controller.itemsInGroup(group.id).map((i) => i.originalName), [
        'song.mp3',
        'video.mp4',
      ]);
      expect(
        controller.items
            .singleWhere((i) => i.originalName == 'video.mp4')
            .category,
        'video',
      );
      expect(controller.isSourceImported(first), isTrue);
      expect(controller.isSourceImported(second), isTrue);
      await File(first.locator).writeAsBytes([9]);
      await File(second.locator).delete();
      final owned = controller.items.singleWhere(
        (i) => i.originalName == 'song.mp3',
      );
      expect(await File(owned.originalPath).readAsBytes(), [1, 2, 3]);
      expect(owned.status, LibraryStatus.needsConversion);
      expect(
        repository.loadItems().every(
          (i) => i.contentHash?.length == 64 && i.sourceKeys.isNotEmpty,
        ),
        isTrue,
      );
      expect(await repository.temporary.list().isEmpty, isTrue);
    },
  );

  test(
    'same content is skipped across different names and persists source aliases',
    () async {
      final a = await make('one.mp3', [1, 2, 3]);
      final b = await make('renamed.mp3', [1, 2, 3]);
      final result = await controller.importScanned([a, b], source);
      expect(result.imported, 1);
      expect(result.skipped, 1);
      expect(controller.items, hasLength(1));
      expect(controller.isSourceImported(b), isTrue);
      expect(
        repository.loadItems().single.sourceKeys,
        containsAll([a.sourceKey, b.sourceKey]),
      );
      expect(await repository.originals.list().length, 1);
      expect(await repository.temporary.list().isEmpty, isTrue);
      await controller.close();
      controller = LibraryController(repository: repository, media: _Media());
      await controller.initialize();
      expect(controller.isSourceImported(a), isTrue);
      expect(controller.isSourceImported(b), isTrue);
    },
  );

  test(
    'same names and sizes with different bytes are not duplicates',
    () async {
      final a = await make('first/song.mp3', [1, 2, 3]);
      final b = await make('second/song.mp3', [4, 5, 6]);
      final result = await controller.importScanned([a, b], source);
      expect(result.imported, 2);
      expect(result.skipped, 0);
    },
  );

  test(
    'legacy records acquire hashes lazily and missing legacy files cannot block import',
    () async {
      final legacyFile = await File(
        p.join(repository.originals.path, 'legacy.mp3'),
      ).writeAsBytes([7, 8, 9]);
      final raw = {
        'id': 'legacy',
        'title': 'old',
        'originalPath': legacyFile.path,
        'originalName': 'legacy.mp3',
        'status': 'needsConversion',
        'importedAt': DateTime(2026).toIso8601String(),
      };
      final legacy = LibraryItem.fromJson(raw);
      expect(legacy.sourceKeys, isEmpty);
      expect(legacy.contentHash, isNull);
      repository.save(legacy);
      await controller.close();
      controller = LibraryController(repository: repository, media: _Media());
      await controller.initialize();
      final candidate = await make('new-name.mp3', [7, 8, 9]);
      final duplicate = await controller.importScanned([candidate], source);
      expect(duplicate.skipped, 1);
      expect(controller.isSourceImported(candidate), isTrue);
      expect(repository.loadItems().single.contentHash, isNotNull);
      await legacyFile.delete();
      final restored = await controller.importScanned([candidate], source);
      expect(restored.imported, 1);
      expect(controller.items.where((i) => i.id != 'legacy'), hasLength(1));
    },
  );

  test(
    'manual imports remain supported and are recognized by later scanning',
    () async {
      final entry = await make('manual.mp3', [1, 5, 9]);
      await controller.importFiles([(path: entry.locator, name: entry.name)]);
      expect(controller.isSourceImported(entry), isTrue);
      final duplicate = await controller.importScanned([entry], source);
      expect(duplicate.skipped, 1);
      expect(controller.items, hasLength(1));
    },
  );

  test(
    'refresh makes a source selectable when its managed copy disappears',
    () async {
      final entry = await make('recover.mp3', [1, 2, 3]);
      await controller.importScanned([entry], source);
      expect(controller.isSourceImported(entry), isTrue);
      await File(controller.items.single.originalPath).delete();
      await controller.refreshAvailableOriginals();
      expect(controller.isSourceImported(entry), isFalse);
      final result = await controller.importScanned([entry], source);
      expect(result.imported, 1);
      expect(result.skipped, 0);
      expect(controller.isSourceImported(entry), isTrue);
    },
  );

  test(
    'inspection clears missing copies but keeps unsupported owned files marked',
    () async {
      final entry = await make('inspect.mp3', [1, 2, 3]);
      await controller.importScanned([entry], source);
      final item = controller.items.single;
      (controller.media as _Media).rejectDecode = true;
      await controller.inspectItem(item.id);
      expect(controller.items.single.status, LibraryStatus.unavailable);
      expect(controller.isSourceImported(entry), isTrue);
      await File(item.originalPath).delete();
      await controller.inspectItem(item.id);
      expect(controller.isSourceImported(entry), isFalse);
    },
  );

  test('playback file loss clears a missing original source marker', () async {
    final entry = await make('playback.flac', [1, 2, 3]);
    await controller.importScanned([entry], source);
    final item = controller.items.single;
    repository.save(
      item.copyWith(
        status: LibraryStatus.ready,
        playablePath: item.originalPath,
      ),
    );
    await controller.close();
    controller = LibraryController(repository: repository, media: _Media());
    await controller.initialize();
    expect(controller.isSourceImported(entry), isTrue);
    await File(item.originalPath).delete();
    expect(await controller.validateForPlayback(item.id), isFalse);
    expect(controller.isSourceImported(entry), isFalse);
  });

  test(
    'changed files fail safely; later files still import and no partial is indexed',
    () async {
      final stale = await make('stale.mp3', [1]);
      final valid = await make('valid.mp3', [2, 3]);
      await File(stale.locator).writeAsBytes([4, 5, 6]);
      final result = await controller.importScanned([stale, valid], source);
      expect(result.failed, 1);
      expect(result.imported, 1);
      expect(result.failures.single, contains('stale.mp3'));
      expect(controller.items.single.originalName, 'valid.mp3');
      expect(await repository.temporary.list().isEmpty, isTrue);
      expect(await repository.originals.list().length, 1);
    },
  );

  test(
    'cancelling mid-copy cleans its partial and retains completed selections',
    () async {
      final a = await make('first.mp3', [1]);
      final b = await make('second.mp3', [2]);
      final started = Completer<void>();
      final cancelled = Completer<void>();
      final hook = _HookSource(
        (entry, destination) async {
          if (entry.sourceId == a.sourceId) {
            return source.copyTo(entry, destination);
          }
          await File(destination).writeAsBytes([2]);
          started.complete();
          await cancelled.future;
          throw const MediaScanCancelled();
        },
        onCancel: () {
          if (!cancelled.isCompleted) cancelled.complete();
        },
      );
      final pending = controller.importScanned([a, b], hook);
      await started.future;
      controller.cancelImport();
      final result = await pending;
      expect(result.cancelled, isTrue);
      expect(result.imported, 1);
      expect(result.failed, 0);
      expect(controller.items.single.originalName, 'first.mp3');
      expect(await repository.temporary.list().isEmpty, isTrue);
      expect(await repository.originals.list().length, 1);
    },
  );

  test(
    'closing waits for active copy cancellation before SQLite can be closed',
    () async {
      final entry = await make('slow.mp3', [1, 2]);
      final started = Completer<void>();
      final stopped = Completer<void>();
      final hook = _HookSource(
        (entry, destination) async {
          await File(destination).writeAsBytes([1]);
          started.complete();
          await stopped.future;
          throw const MediaScanCancelled();
        },
        onCancel: () {
          if (!stopped.isCompleted) stopped.complete();
        },
      );
      final pending = controller.importScanned([entry], hook);
      await started.future;
      await controller.close();
      expect((await pending).cancelled, isTrue);
      expect(repository.loadItems(), isEmpty);
      expect(await repository.temporary.list().isEmpty, isTrue);
    },
  );

  test('a deleted target group cannot leave an orphan assignment', () async {
    final entry = await make('song.mp3', [1, 2]);
    final group = controller.createGroup('临时');
    final hook = _HookSource((entry, destination) async {
      await source.copyTo(entry, destination);
      controller.deleteGroup(group.id);
    });
    final result = await controller.importScanned(
      [entry],
      hook,
      groupId: group.id,
    );
    expect(result.failed, 1);
    expect(controller.items, isEmpty);
    expect(await repository.originals.list().isEmpty, isTrue);
    expect(await repository.temporary.list().isEmpty, isTrue);
  });
}
