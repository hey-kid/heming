import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/features/library/library_page.dart';
import 'package:heming/preview/preview_controller.dart';

class UnusedMedia implements MediaBackend {
  @override
  Future<AudioMetadata> inspect(String path, {bool verifyDecode = false}) =>
      throw UnimplementedError();
  @override
  Future<void> convert(
    String inputPath,
    String outputPath,
    ConversionToken token,
    void Function(double) onProgress,
  ) => throw UnimplementedError();
}

class WidgetPreviewAudio implements PreviewAudioPort {
  @override
  PreviewStatus status = const PreviewStatus(PreviewState.idle);
  @override
  Stream<PreviewStatus> get statuses => const Stream.empty();
  int seeks = 0;
  @override
  Future<void> open(String path) async {
    status = const PreviewStatus(PreviewState.paused, durationMs: 120000);
  }

  @override
  Future<void> play() async {
    status = PreviewStatus(
      PreviewState.playing,
      durationMs: status.durationMs,
      positionMs: status.positionMs,
    );
  }

  @override
  Future<void> pause() async {
    status = PreviewStatus(
      PreviewState.paused,
      durationMs: status.durationMs,
      positionMs: status.positionMs,
    );
  }

  @override
  Future<void> seek(int positionMs) async {
    seeks++;
    status = PreviewStatus(
      status.state,
      positionMs: positionMs,
      durationMs: status.durationMs,
    );
  }

  @override
  Future<void> stop() async {
    status = const PreviewStatus(PreviewState.idle);
  }

  @override
  void setVolume(double volume) {}
  @override
  Future<void> dispose() async {}
}

void main() {
  for (final width in [320.0, 1280.0]) {
    testWidgets('group list plays whole ordered group and fits $width px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late LibraryRepository repository;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('heming-library-page-');
        repository = await LibraryRepository.open(root);
        final original = await File(
          '${root.path}/song.flac',
        ).writeAsBytes([1, 2, 3]);
        for (var i = 0; i < 6; i++) {
          repository.save(
            LibraryItem(
              id: 'song-$i',
              title: '歌曲 $i',
              originalPath: original.path,
              originalName: 'song.flac',
              playablePath: original.path,
              status: LibraryStatus.ready,
              importedAt: DateTime(2026, 11, 11, 0, i),
            ),
          );
        }
      });
      final library = LibraryController(
        repository: repository,
        media: UnusedMedia(),
      );
      await tester.runAsync(library.initialize);
      final group = library.createGroup('晚间音乐');
      library.moveItemsToGroup(['song-0', 'song-1', 'song-2'], group.id);
      library.moveItemInGroup('song-2', -1);
      List<LibraryItem>? played;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: ListenableBuilder(
                listenable: library,
                builder: (_, _) => LibraryPage(
                  library: library,
                  canPlay: true,
                  onPlay: (_) async {},
                  onPlaylist: (items) async => played = items,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byType(DropdownButtonFormField<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('晚间音乐').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '歌曲 2');
      await tester.pumpAndSettle();
      expect(find.text('歌曲 0'), findsNothing);
      await tester.ensureVisible(find.text('播放本组'));
      await tester.tap(find.text('播放本组'));
      await tester.pumpAndSettle();
      expect(played?.map((item) => item.id), ['song-0', 'song-2', 'song-1']);
      await tester.ensureVisible(find.text('批量管理'));
      await tester.tap(find.text('批量管理'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.byType(Checkbox).first);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.text('移动 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      library.dispose();
      repository.close();
      await tester.runAsync(() => root.delete(recursive: true));
    });
  }

  testWidgets(
    'local preview controls fit narrow screen and hidden preview stops',
    (tester) async {
      tester.view.physicalSize = const Size(320, 1100);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late LibraryRepository repository;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('heming-preview-page-');
        repository = await LibraryRepository.open(root);
        final original = await File(
          '${root.path}/sample.mp3',
        ).writeAsBytes([1, 2, 3]);
        repository.save(
          LibraryItem(
            id: 'preview-song',
            title: '尚未转换的歌曲',
            originalPath: original.path,
            originalName: 'sample.mp3',
            status: LibraryStatus.needsConversion,
            importedAt: DateTime(2026, 11, 11),
          ),
        );
      });
      final library = LibraryController(
        repository: repository,
        media: UnusedMedia(),
      );
      await tester.runAsync(library.initialize);
      final audio = WidgetPreviewAudio();
      final preview = PreviewController(
        audio: audio,
        canPlay: () => true,
        acquireFocus: () async => true,
        releaseFocus: () async {},
      );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: LibraryPage(
                library: library,
                canPlay: false,
                canPreview: true,
                preview: preview,
                onPlay: (_) async {},
                onPlaylist: (_) async {},
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('转换'), findsOneWidget);
      await tester.ensureVisible(find.text('试听'));
      await tester.tap(find.text('试听'));
      await tester.pumpAndSettle();
      expect(preview.state, PreviewState.playing);
      expect(find.byType(Slider), findsOneWidget);
      await tester.ensureVisible(find.byTooltip('暂停试听'));
      await tester.tap(find.byTooltip('暂停试听'));
      await tester.pumpAndSettle();
      expect(preview.state, PreviewState.paused);
      await tester.drag(find.byType(Slider), const Offset(70, 0));
      await tester.pumpAndSettle();
      expect(audio.seeks, 1);
      await tester.tap(find.byTooltip('继续试听'));
      await tester.pumpAndSettle();
      expect(preview.state, PreviewState.playing);
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('视频'));
      await tester.tap(find.text('视频'));
      await tester.pumpAndSettle();
      expect(preview.itemId, isNull);
      expect(find.byType(Slider), findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(preview.close);
      library.dispose();
      repository.close();
      await tester.runAsync(() => root.delete(recursive: true));
    },
  );
}
