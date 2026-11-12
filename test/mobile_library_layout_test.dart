import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/features/library/library_page.dart';
import 'package:heming/preview/preview_controller.dart';

class _UnusedMedia implements MediaBackend {
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

class _PreviewAudio implements PreviewAudioPort {
  @override
  PreviewStatus status = const PreviewStatus(PreviewState.idle);
  @override
  Stream<PreviewStatus> get statuses => const Stream.empty();
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
    status = PreviewStatus(
      status.state,
      durationMs: status.durationMs,
      positionMs: positionMs,
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
  for (final scenario in [
    (width: 360.0, scale: 1.15, brightness: Brightness.light),
    (width: 320.0, scale: 1.4, brightness: Brightness.light),
    (width: 320.0, scale: 1.6, brightness: Brightness.dark),
  ]) {
    testWidgets(
      'mobile library remains usable at ${scenario.width}px / ${scenario.scale}x text',
      (tester) async {
        tester.view.physicalSize = Size(scenario.width, 740);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        late Directory temporary;
        late LibraryRepository repository;
        const title = '夜色里的轻音乐与远方的海浪，这是一个较长的音乐名称';
        await tester.runAsync(() async {
          temporary = await Directory.systemTemp.createTemp(
            'heming-mobile-library-',
          );
          repository = await LibraryRepository.open(temporary);
          final original = await File(
            '${temporary.path}/sample.flac',
          ).writeAsBytes([1, 2, 3]);
          for (var i = 0; i < 7; i++) {
            repository.save(
              LibraryItem(
                id: 'song-$i',
                title: i == 0 ? title : '晚间收藏 $i',
                originalPath: original.path,
                originalName: 'sample.flac',
                playablePath: i == 1 ? null : original.path,
                status: i == 1
                    ? LibraryStatus.needsConversion
                    : LibraryStatus.ready,
                importedAt: DateTime(2026, 11, 11, 0, 7 - i),
                metadata: const AudioMetadata(
                  codec: 'flac',
                  sampleRate: 48000,
                  channels: 2,
                  bitsPerSample: 16,
                  durationMs: 120000,
                  verified: true,
                ),
              ),
            );
          }
        });
        final library = LibraryController(
          repository: repository,
          media: _UnusedMedia(),
        );
        await tester.runAsync(library.initialize);
        final group = library.createGroup('晚间放松与阅读时光');
        library.moveItemsToGroup(['song-0', 'song-1'], group.id);
        final preview = PreviewController(
          audio: _PreviewAudio(),
          canPlay: () => true,
          acquireFocus: () async => true,
          releaseFocus: () async {},
        );
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: hemingTheme(scenario.brightness, mobile: true),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(scenario.scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: ListenableBuilder(
                    listenable: library,
                    builder: (_, _) => LibraryPage(
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
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          // Search and filtering must leave the actual music within the first
          // viewport even with a larger accessibility text size.
          expect(tester.getTopLeft(find.text(title)).dy, lessThan(640));

          await tester.tap(find.byTooltip('分组操作'));
          await tester.pumpAndSettle();
          expect(find.text('新建分组'), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tapAt(const Offset(8, 8));
          await tester.pumpAndSettle();

          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text(group.name).last);
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);

          await tester.ensureVisible(find.text('试听').first);
          await tester.tap(find.text('试听').first);
          await tester.pumpAndSettle();
          expect(preview.itemId, 'song-0');
          expect(find.byType(Slider), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byTooltip('结束试听'));
          await tester.tap(find.byTooltip('结束试听'));
          await tester.pumpAndSettle();
          expect(preview.itemId, isNull);

          await tester.ensureVisible(find.text('批量管理'));
          await tester.tap(find.text('批量管理'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.byType(Checkbox).first);
          await tester.tap(find.byType(Checkbox).first);
          await tester.pumpAndSettle();
          expect(find.text('移动 1 项'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(preview.close);
          library.dispose();
          repository.close();
          await tester.runAsync(() => temporary.delete(recursive: true));
        }
      },
    );
  }
}
