import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/data/media_scan.dart';
import 'package:heming/data/native_media_backend.dart';
import 'package:heming/preview/native_preview_audio_port.dart';
import 'package:heming/preview/preview_controller.dart';
import 'package:heming/preview/scan_preview_controller.dart';
import 'package:heming_platform/heming_platform.dart';
import 'package:integration_test/integration_test.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

Uint8List silentFixture() {
  final data = ByteData(44 + 48000 * 4 * 8);
  void tag(int offset, String value) {
    for (var i = 0; i < value.length; i++) {
      data.setUint8(offset + i, value.codeUnitAt(i));
    }
  }

  tag(0, 'RIFF');
  data.setUint32(4, data.lengthInBytes - 8, Endian.little);
  tag(8, 'WAVEfmt ');
  data.setUint32(16, 16, Endian.little);
  data.setUint16(20, 1, Endian.little);
  data.setUint16(22, 2, Endian.little);
  data.setUint32(24, 48000, Endian.little);
  data.setUint32(28, 192000, Endian.little);
  data.setUint16(32, 4, Endian.little);
  data.setUint16(34, 16, Endian.little);
  tag(36, 'data');
  data.setUint32(40, data.lengthInBytes - 44, Endian.little);
  return data.buffer.asUint8List();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('native media discovery copies selected fixtures independently', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: Center(child: Text('正在验证本机媒体扫描'))),
      ),
    );
    final parent = await getTemporaryDirectory();
    final root = await parent.createTemp('heming-scan-smoke-');
    final fixtures = await Directory(p.join(root.path, 'source')).create();
    final managed = Directory(p.join(root.path, 'managed'));
    final repository = await LibraryRepository.open(managed);
    final platform = HemingPlatform();
    final library = LibraryController(
      repository: repository,
      media: NativeMediaBackend(platform),
    );
    await library.initialize();
    final source = SystemMediaScanSource();
    final player = PreviewController(
      audio: NativePreviewAudioPort(),
      canPlay: () => true,
      acquireFocus: platform.acquirePreviewAudioFocus,
      releaseFocus: platform.releasePreviewAudioFocus,
    )..setVolume(0);
    final preview = ScanPreviewController(player: player);
    final entries = <MediaScanEntry>[];
    const fixtureName = 'heming-scan-smoke-audio.wav';
    try {
      if (Platform.isWindows) {
        final defaults = await const MethodChannel(
          'heming_media_scan',
        ).invokeListMethod<String>('defaultFolders');
        expect(defaults, isNotEmpty);
        await File(
          p.join(fixtures.path, fixtureName),
        ).writeAsBytes(silentFixture());
        await File(
          p.join(managed.path, 'must-not-scan.wav'),
        ).writeAsBytes(silentFixture());
      }
      await for (final batch in source.scan(
        folders: Platform.isWindows ? [fixtures.path, managed.path] : const [],
        excludedPaths: [managed.path],
        requestPermission: true,
      )) {
        entries.addAll(batch.entries);
      }
      expect(
        entries.where((entry) => entry.locator.startsWith(managed.path)),
        isEmpty,
      );
      final fixture = entries.singleWhere((entry) => entry.name == fixtureName);
      expect(fixture.category, 'audio');
      expect(fixture.sizeBytes, greaterThan(44));
      // Preview the source before any import, through actual native audio and
      // Android's separate URI-to-cache path. Generated fixtures are silent.
      await preview.play(fixture);
      expect(preview.state, PreviewState.playing, reason: preview.error);
      expect(library.items, isEmpty);
      await tester.pump(const Duration(milliseconds: 100));
      await preview.togglePause();
      expect(preview.state, PreviewState.paused);
      expect(preview.durationMs, greaterThan(0));
      await preview.seek(100);
      await preview.togglePause();
      expect(preview.state, PreviewState.playing);
      await preview.stop();
      expect(player.isActive, isFalse);
      expect(preview.isActive, isFalse);
      expect(library.items, isEmpty);
      debugPrint(
        'HEMING_SCAN_PREVIEW_OK platform=${Platform.operatingSystem} '
        'paused=true seeked=true stopped=true imported=0',
      );
      final group = library.createGroup('扫描验证');
      final imported = await library.importScanned(
        [fixture],
        source,
        groupId: group.id,
      );
      expect(imported.imported, 1, reason: imported.failures.join('\n'));
      expect(imported.failed, 0);
      final item = library.items.single;
      expect(item.groupId, group.id);
      expect(item.metadata?.codec, 'wav');
      expect(await File(item.originalPath).length(), fixture.sizeBytes);
      expect(item.originalPath, isNot(fixture.locator));
      final copiedBytes = await File(item.originalPath).readAsBytes();
      final repeated = await library.importScanned([fixture], source);
      expect(repeated.skipped, 1);
      expect(library.items, hasLength(1));
      expect(library.isSourceImported(fixture), isTrue);
      if (Platform.isWindows) {
        await File(fixture.locator).writeAsBytes([1, 2, 3]);
        expect(await File(item.originalPath).readAsBytes(), copiedBytes);
      }
      // A video remains a video source after copying; its soundtrack is inspected.
      if (Platform.isAndroid) {
        final video = entries.singleWhere(
          (entry) => entry.name == 'heming-scan-smoke-video.mp4',
        );
        expect(video.category, 'video');
        final result = await library.importScanned([video], source);
        expect(result.imported, 1, reason: result.failures.join('\n'));
        expect(library.items.first.category, 'video');
        expect(library.items.first.metadata?.durationMs, greaterThan(0));
      }
      debugPrint(
        'HEMING_SCAN_SMOKE_OK platform=${Platform.operatingSystem} imported=${library.items.length} independentCopy=true duplicatesSkipped=true',
      );
    } finally {
      await preview.close();
      await player.close();
      await source.cancel();
      await library.close();
      await platform.dispose();
      repository.close();
      // Only this test's fresh temporary directory is removed.
      await root.delete(recursive: true);
    }
  });
}
