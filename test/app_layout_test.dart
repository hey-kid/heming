import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/heming_app.dart';
import 'package:heming/app/preferences.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/session/session_controller.dart';

class NoAudio extends AudioSessionPort {
  @override
  int get monotonicMicros => 0;
  @override
  Stream<PlaybackAudioStatus> get statuses => const Stream.empty();
  @override
  Future<AudioPreparation> prepareMaster(
    PlayableTrack track, {
    required String sessionId,
    required String taskId,
  }) async => const AudioPreparation(port: 0, totalFrames: 0);
  @override
  Future<void> prepareFollower({
    required String host,
    required int port,
    required String sessionId,
    required String taskId,
  }) async {}
  @override
  void scheduleStart(int masterTimeUs) {}
  @override
  void setOutput({
    required double volume,
    required AudioChannel channel,
    required bool muted,
  }) {}
  @override
  Future<void> stop() async {}
  @override
  Future<void> dispose() async {}
}

class NoMedia implements MediaBackend {
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

void main() {
  for (final size in [
    const Size(320, 700),
    const Size(390, 844),
    const Size(860, 700),
    const Size(860, 420),
    const Size(1024, 768),
    const Size(1280, 800),
  ]) {
    testWidgets(
      'device/library/playback/settings fit ${size.width.toInt()}x${size.height.toInt()} in both themes',
      (tester) async {
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        tester.platformDispatcher.textScaleFactorTestValue = size.height < 500
            ? 1.6
            : 1;
        addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        late Directory root;
        late LibraryRepository repository;
        await tester.runAsync(() async {
          root = await Directory.systemTemp.createTemp('heming-layout-test-');
          repository = await LibraryRepository.open(root);
          final original = await File(
            '${root.path}/sample.flac',
          ).writeAsBytes([1, 2, 3]);
          for (final entry in [
            LibraryStatus.ready,
            LibraryStatus.needsConversion,
            LibraryStatus.failed,
          ].indexed) {
            repository.save(
              LibraryItem(
                id: 'item-${entry.$1}',
                title: entry.$1 == 2
                    ? '很长的资源名称用于验证在手机窄屏上自动换行不会遮挡转换操作'
                    : '测试音频 ${entry.$1 + 1}',
                originalPath: original.path,
                originalName: 'sample.flac',
                status: entry.$2,
                importedAt: DateTime(2026, 11, 10),
                playablePath: entry.$2 == LibraryStatus.ready
                    ? original.path
                    : null,
                metadata: const AudioMetadata(
                  codec: 'flac',
                  sampleRate: 48000,
                  channels: 2,
                  bitsPerSample: 16,
                  durationMs: 120000,
                  verified: true,
                ),
                error: entry.$2 == LibraryStatus.failed
                    ? '无法读取此资源的音轨，原文件已保留。请检查文件后重试。'
                    : null,
              ),
            );
          }
        });
        final library = LibraryController(
          repository: repository,
          media: NoMedia(),
        );
        await tester.runAsync(library.initialize);
        final preferences = Preferences(repository);
        final session = SessionController(
          audio: NoAudio(),
          deviceId: 'local-device',
          deviceName: '客厅电脑',
          platformName: 'Windows',
        );
        await tester.pumpWidget(
          HemingApp(
            session: session,
            library: library,
            preferences: preferences,
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text('一起聆听'), findsOneWidget);
        expect(tester.takeException(), isNull);
        for (final theme in [ThemeMode.light, ThemeMode.dark]) {
          preferences.setTheme(theme);
          await tester.pumpAndSettle();
          for (final label in ['资源库', '正在播放', '设置', '设备']) {
            final finder = size.width >= 860
                ? find.descendant(
                    of: find.byKey(const ValueKey('desktop-sidebar')),
                    matching: find.text(label),
                  )
                : find.text(label).last;
            await tester.ensureVisible(finder);
            await tester.tap(finder);
            await tester.pumpAndSettle();
            expect(
              tester.takeException(),
              isNull,
              reason: '$label at $size / $theme',
            );
          }
        }
        await tester.pumpWidget(const SizedBox());
        await session.shutdown();
        library.dispose();
        preferences.dispose();
        repository.close();
        await tester.runAsync(() async {
          await root.delete(recursive: true);
        });
      },
    );
  }
}
