import 'dart:async';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:path/path.dart' as p;

class TestMedia implements MediaBackend {
  int conversions = 0;
  int active = 0;
  int peakActive = 0;
  bool invalidOutput = false;
  bool waitUntilCancelled = false;
  @override
  Future<AudioMetadata> inspect(
    String path, {
    bool verifyDecode = false,
  }) async {
    final bytes = await File(path).readAsBytes();
    final canonical = bytes.isNotEmpty && bytes.first == 99 && !invalidOutput;
    return AudioMetadata(
      codec: canonical ? 'flac' : 'mp3',
      sampleRate: canonical ? 48000 : 44100,
      channels: 2,
      bitsPerSample: 16,
      durationMs: 2000,
      verified: verifyDecode && canonical,
    );
  }

  @override
  Future<void> convert(
    String inputPath,
    String outputPath,
    ConversionToken token,
    void Function(double) onProgress,
  ) async {
    conversions++;
    active++;
    if (active > peakActive) peakActive = active;
    try {
      await File(outputPath).writeAsBytes([99, 0, 1, 2]);
      if (waitUntilCancelled) {
        final cancelled = Completer<void>();
        token.onCancel = () {
          if (!cancelled.isCompleted) cancelled.complete();
        };
        if (token.isCancelled) cancelled.complete();
        await cancelled.future;
        token.throwIfCancelled();
      }
      await Future<void>.delayed(const Duration(milliseconds: 10));
      onProgress(1);
    } finally {
      active--;
    }
  }
}

Future<void> eventually(bool Function() condition) async {
  final deadline = DateTime.now().add(const Duration(seconds: 4));
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      throw TimeoutException('Condition was not reached');
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
}

void main() {
  late Directory root;
  late LibraryRepository repository;
  late LibraryController controller;
  late TestMedia media;
  late File source;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('heming-library-test-');
    repository = await LibraryRepository.open(
      Directory(p.join(root.path, 'app')),
    );
    media = TestMedia();
    controller = LibraryController(repository: repository, media: media);
    await controller.initialize();
    source = await File(
      p.join(root.path, 'original.mp3'),
    ).writeAsBytes([1, 5, 9, 13]);
  });
  tearDown(() async {
    controller.dispose();
    repository.close();
    await root.delete(recursive: true);
  });

  test(
    'import preserves source bytes and never converts; explicit conversion commits a verified copy',
    () async {
      await controller.importFiles([(path: source.path, name: '一首歌.mp3')]);
      final imported = controller.items.single;
      expect(media.conversions, 0);
      expect(imported.status, LibraryStatus.needsConversion);
      expect(await File(imported.originalPath).readAsBytes(), [1, 5, 9, 13]);
      controller.requestConversion(imported.id);
      await eventually(() => controller.items.single.isPlayable);
      final ready = controller.items.single;
      expect(ready.playablePath, isNot(ready.originalPath));
      expect(await source.readAsBytes(), [1, 5, 9, 13]);
      expect(await File(ready.originalPath).readAsBytes(), [1, 5, 9, 13]);
      expect(repository.loadItems().single.isPlayable, isTrue);
      expect(await repository.temporary.list().isEmpty, isTrue);
    },
  );

  test(
    'canonical content is detected independently of its extension and verified without conversion',
    () async {
      await source.writeAsBytes([99, 0, 1]);
      await controller.importFiles([(path: source.path, name: '实际是FLAC.bin')]);
      expect(controller.items.single.isPlayable, isTrue);
      expect(
        controller.items.single.playablePath,
        controller.items.single.originalPath,
      );
      expect(media.conversions, 0);
    },
  );

  test(
    'failed verification never marks partial output playable and preserves originals',
    () async {
      await controller.importFiles([(path: source.path, name: 'source.mp3')]);
      media.invalidOutput = true;
      controller.requestConversion(controller.items.single.id);
      await eventually(
        () => controller.items.single.status == LibraryStatus.failed,
      );
      expect(controller.items.single.playablePath, isNull);
      expect(await repository.temporary.list().isEmpty, isTrue);
      expect(await source.readAsBytes(), [1, 5, 9, 13]);
    },
  );

  test(
    'cancelling conversion removes temporary output and leaves resource pending',
    () async {
      await controller.importFiles([(path: source.path, name: 'source.mp3')]);
      media.waitUntilCancelled = true;
      final id = controller.items.single.id;
      controller.requestConversion(id);
      await eventually(() => media.active == 1);
      controller.cancelConversion(id);
      await eventually(
        () =>
            controller.items.single.status == LibraryStatus.needsConversion &&
            controller.activeConversionId == null,
      );
      expect(await repository.temporary.list().isEmpty, isTrue);
      expect(controller.items.single.playablePath, isNull);
      expect(await source.readAsBytes(), [1, 5, 9, 13]);
    },
  );

  test(
    'conversion queue is serial; duplicate requests do not create duplicates',
    () async {
      await controller.importFiles([
        (path: source.path, name: 'a.mp3'),
        (path: source.path, name: 'b.mp3'),
      ]);
      for (final item in controller.items) {
        controller.requestConversion(item.id);
        controller.requestConversion(item.id);
      }
      await eventually(
        () =>
            controller.playableCount == 2 &&
            controller.activeConversionId == null,
      );
      expect(media.conversions, 2);
      expect(media.peakActive, 1);
    },
  );

  test(
    'closing waits for cancellation and prevents queued conversion from starting',
    () async {
      await controller.importFiles([
        (path: source.path, name: 'a.mp3'),
        (path: source.path, name: 'b.mp3'),
      ]);
      media.waitUntilCancelled = true;
      for (final item in controller.items) {
        controller.requestConversion(item.id);
      }
      await eventually(() => media.active == 1);
      await controller.close();
      expect(media.active, 0);
      expect(media.conversions, 1);
      expect(await repository.temporary.list().isEmpty, isTrue);
      expect(repository.loadItems().any((item) => item.isPlayable), isFalse);
    },
  );

  test('cancelling a queued job does not cancel the active one', () async {
    await controller.importFiles([
      (path: source.path, name: 'a.mp3'),
      (path: source.path, name: 'b.mp3'),
    ]);
    final first = controller.items.first.id;
    final second = controller.items.last.id;
    controller.requestConversion(first);
    controller.requestConversion(second);
    controller.cancelConversion(second);
    await eventually(
      () =>
          controller.playableCount == 1 &&
          controller.activeConversionId == null,
    );
    expect(media.conversions, 1);
    expect(controller.items.first.isPlayable, isTrue);
    expect(controller.items.last.status, LibraryStatus.needsConversion);
  });

  test(
    'file loss invalidates playback and deleting a library item never deletes source',
    () async {
      await source.writeAsBytes([99, 1, 2]);
      await controller.importFiles([(path: source.path, name: 'source.flac')]);
      final item = controller.items.single;
      await File(item.playablePath!).delete();
      expect(await controller.validateForPlayback(item.id), isFalse);
      expect(controller.items.single.status, LibraryStatus.unavailable);
      await controller.remove(item.id);
      expect(controller.items, isEmpty);
      expect(await source.readAsBytes(), [99, 1, 2]);
    },
  );
}
