import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/features/library/library_page.dart';
import 'package:heming/preview/preview_controller.dart';

import 'library_page_test.dart' show UnusedMedia, WidgetPreviewAudio;

void main() {
  for (final configuration in [
    (width: 584.0, scale: 1.3, brightness: Brightness.dark),
    (width: 860.0, scale: 1.0, brightness: Brightness.light),
    (width: 1160.0, scale: 1.15, brightness: Brightness.dark),
  ]) {
    testWidgets(
      'desktop library uses compact rows at ${configuration.width}px content',
      (tester) async {
        tester.view.physicalSize = const Size(1600, 1000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory temporary;
        late LibraryRepository repository;
        const firstTitle = '阅读时光里的钢琴与自然声音，这是用于验证横向列表的较长标题';
        await tester.runAsync(() async {
          temporary = await Directory.systemTemp.createTemp(
            'heming-desktop-library-',
          );
          repository = await LibraryRepository.open(temporary);
          final original = await File(
            '${temporary.path}/desktop.flac',
          ).writeAsBytes([1, 2, 3]);
          for (var index = 0; index < 7; index++) {
            repository.save(
              LibraryItem(
                id: 'desktop-$index',
                title: index == 0 ? firstTitle : '音乐收藏 $index',
                originalPath: original.path,
                originalName: 'desktop.flac',
                playablePath: index == 1 ? null : original.path,
                status: index == 1
                    ? LibraryStatus.needsConversion
                    : LibraryStatus.ready,
                importedAt: DateTime(2026, 11, 12, 0, 7 - index),
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
          media: UnusedMedia(),
        );
        await tester.runAsync(library.initialize);
        final group = library.createGroup('晚间阅读与放松');
        library.moveItemsToGroup(['desktop-0', 'desktop-1'], group.id);
        final preview = PreviewController(
          audio: WidgetPreviewAudio(),
          canPlay: () => true,
          acquireFocus: () async => true,
          releaseFocus: () async {},
        );
        final audition = ValueNotifier(false);
        List<String>? played;
        try {
          await tester.pumpWidget(
            MaterialApp(
              theme: hemingTheme(configuration.brightness),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(
                  context,
                ).copyWith(textScaler: TextScaler.linear(configuration.scale)),
                child: child!,
              ),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(24),
                  child: Center(
                    child: SizedBox(
                      width: configuration.width,
                      child: ListenableBuilder(
                        listenable: Listenable.merge([library, audition]),
                        builder: (_, _) => LibraryPage(
                          library: library,
                          canPlay: !audition.value,
                          canPreview: audition.value,
                          preview: preview,
                          onPlay: (_) async {},
                          onPlaylist: (items) async =>
                              played = items.map((item) => item.id).toList(),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          expect(tester.getTopLeft(find.text(firstTitle)).dy, lessThan(500));
          expect(
            tester.getSize(find.byKey(const ValueKey('desktop-0'))).height,
            lessThan(140),
          );

          await tester.tap(find.byType(DropdownButtonFormField<String>));
          await tester.pumpAndSettle();
          await tester.tap(find.text(group.name).last);
          await tester.pumpAndSettle();
          await tester.tap(find.text('播放本组'));
          await tester.pumpAndSettle();
          expect(played, ['desktop-0', 'desktop-1']);

          await tester.tap(find.byTooltip('分组操作'));
          await tester.pumpAndSettle();
          expect(find.text('新建分组'), findsOneWidget);
          expect(find.text('重命名分组'), findsOneWidget);
          expect(find.text('删除分组'), findsOneWidget);
          await tester.tapAt(const Offset(4, 4));
          await tester.pumpAndSettle();
          await tester.tap(find.byTooltip('资源操作').first);
          await tester.pumpAndSettle();
          await tester.tap(find.text('资源详情'));
          await tester.pumpAndSettle();
          expect(find.byType(SelectableText), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.tap(find.text('关闭'));
          await tester.pumpAndSettle();

          audition.value = true;
          await tester.pumpAndSettle();
          expect(find.text('播放本组'), findsNothing);
          await tester.tap(find.text('试听').first);
          await tester.pumpAndSettle();
          expect(preview.itemId, 'desktop-0');
          expect(find.byType(Slider), findsOneWidget);
          expect(tester.takeException(), isNull);
          await tester.ensureVisible(find.byTooltip('结束试听'));
          await tester.tap(find.byTooltip('结束试听'));
          await tester.pumpAndSettle();
          await tester.ensureVisible(find.text('批量管理'));
          await tester.tap(find.text('批量管理'));
          await tester.pumpAndSettle();
          await tester.tap(find.byType(Checkbox).first);
          await tester.pumpAndSettle();
          expect(find.text('移动 1 项'), findsOneWidget);
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox());
          await tester.runAsync(preview.close);
          audition.dispose();
          library.dispose();
          repository.close();
          await tester.runAsync(() => temporary.delete(recursive: true));
        }
      },
    );
  }
}
