import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/data/media_scan.dart';
import 'package:heming/data/media_source_actions.dart';
import 'package:heming/features/library/media_scan_page.dart';
import 'package:heming/preview/preview_controller.dart';
import 'package:heming/preview/scan_preview_controller.dart';

class _PreviewAudio implements PreviewAudioPort {
  final _events = StreamController<PreviewStatus>.broadcast(sync: true);
  final opened = <String>[];
  int stops = 0;
  Completer<void>? stopGate;
  @override
  PreviewStatus status = const PreviewStatus(PreviewState.idle);
  @override
  Stream<PreviewStatus> get statuses => _events.stream;
  void _emit(PreviewState state, [int position = 0]) {
    status = PreviewStatus(state, positionMs: position, durationMs: 90000);
    _events.add(status);
  }

  @override
  Future<void> open(String path) async {
    opened.add(path);
    _emit(PreviewState.paused);
  }

  @override
  Future<void> play() async => _emit(PreviewState.playing, status.positionMs);
  @override
  Future<void> pause() async => _emit(PreviewState.paused, status.positionMs);
  @override
  Future<void> seek(int positionMs) async => _emit(status.state, positionMs);
  @override
  Future<void> stop() async {
    stops++;
    await stopGate?.future;
    _emit(PreviewState.idle);
  }

  @override
  void setVolume(double volume) {}
  @override
  Future<void> dispose() => _events.close();
}

class _PreviewAccess implements ScanPreviewAccess {
  final prepared = <MediaScanEntry>[];
  int released = 0;
  @override
  Future<PreparedPreviewSource> prepare(MediaScanEntry entry) async {
    prepared.add(entry);
    return PreparedPreviewSource(
      path: '${entry.sourceId}.wav',
      release: () async {
        released++;
      },
    );
  }

  @override
  Future<void> cancel() async {}
}

class _SourceActions extends MediaSourceActions {
  final opened = <MediaScanEntry>[], revealed = <MediaScanEntry>[];
  @override
  Future<void> open(MediaScanEntry entry) async {
    opened.add(entry);
  }

  @override
  Future<void> reveal(MediaScanEntry entry) async {
    revealed.add(entry);
  }
}

MediaScanEntry _entry(String id, {bool video = false, int size = 128}) =>
    MediaScanEntry(
      sourceId: id,
      locator: 'content://media/$id',
      name: '$id.${video ? 'mp4' : 'mp3'}',
      category: video ? 'video' : 'audio',
      sizeBytes: size,
      modifiedMs: 1000,
      durationMs: 90000,
      folder: video ? 'Movies' : 'Music',
    );

class _FakeScanSource implements MediaScanSource {
  _FakeScanSource(this.entries);
  List<MediaScanEntry> entries;
  String audioAccess = 'full', videoAccess = 'full';
  final permissionRequests = <bool>[];
  final excludedRoots = <List<String>>[];
  Completer<void>? cancelGate;
  Completer<void>? scanGate;

  @override
  Stream<MediaScanBatch> scan({
    List<String> folders = const [],
    required List<String> excludedPaths,
    bool requestPermission = false,
  }) async* {
    permissionRequests.add(requestPermission);
    excludedRoots.add(List.of(excludedPaths));
    final snapshot = MediaScanBatch(
      entries: List.of(entries),
      audioAccess: audioAccess,
      videoAccess: videoAccess,
    );
    final pending = scanGate;
    await pending?.future;
    if (identical(scanGate, pending)) scanGate = null;
    yield snapshot;
  }

  @override
  Future<void> cancel() async {
    await cancelGate?.future;
  }

  @override
  Future<void> copyTo(MediaScanEntry entry, String destination) =>
      throw StateError('UI tests must use the recording import controller.');
}

class _NoMedia implements MediaBackend {
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

/// Records the UI's import contract; real copying and deduplication are covered
/// by the controller tests, without file IO inside Flutter's fake async clock.
class _RecordingLibrary extends LibraryController {
  _RecordingLibrary(LibraryRepository repository)
    : super(repository: repository, media: _NoMedia());

  final importedSourceKeys = <String>{};
  final imports = <List<MediaScanEntry>>[];
  String? targetGroup;
  void Function()? beforeImport;

  @override
  bool isSourceImported(MediaScanEntry entry) =>
      importedSourceKeys.contains(entry.sourceKey);

  @override
  Future<MediaImportResult> importScanned(
    List<MediaScanEntry> entries,
    MediaScanSource source, {
    String? groupId,
  }) async {
    beforeImport?.call();
    imports.add(List.of(entries));
    targetGroup = groupId;
    importing = true;
    notifyListeners();
    await Future<void>.value();
    importedSourceKeys.addAll(entries.map((entry) => entry.sourceKey));
    importing = false;
    notifyListeners();
    return MediaImportResult(imported: entries.length);
  }
}

class _Harness {
  const _Harness(
    this.library,
    this.source,
    this.preview,
    this.audio,
    this.access,
    this.actions,
  );
  final _RecordingLibrary library;
  final _FakeScanSource source;
  final ScanPreviewController? preview;
  final _PreviewAudio audio;
  final _PreviewAccess access;
  final _SourceActions actions;
}

Future<_Harness> _mount(
  WidgetTester tester, {
  List<MediaScanEntry>? entries,
  bool android = false,
  String audioAccess = 'full',
  String videoAccess = 'full',
  Set<String> imported = const {},
  bool createGroup = false,
  Size size = const Size(1000, 1000),
  double textScale = 1,
  Brightness brightness = Brightness.light,
  bool withPreview = false,
  bool canPreview = true,
  bool route = false,
}) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  addTearDown(tester.view.resetViewInsets);
  late Directory root;
  late LibraryRepository repository;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('heming-scan-page-');
    repository = await LibraryRepository.open(root);
  });
  final library = _RecordingLibrary(repository)
    ..importedSourceKeys.addAll(imported);
  await tester.runAsync(library.initialize);
  if (createGroup) library.createGroup('夜间音乐');
  final source =
      _FakeScanSource(
          entries ??
              [
                _entry('audio-a'),
                _entry('audio-b'),
                _entry('video', video: true),
              ],
        )
        ..audioAccess = audioAccess
        ..videoAccess = videoAccess;
  final audio = _PreviewAudio();
  final access = _PreviewAccess();
  final actions = _SourceActions();
  final player = PreviewController(
    audio: audio,
    canPlay: () => canPreview,
    acquireFocus: () async => true,
    releaseFocus: () async {},
  );
  final preview = withPreview
      ? ScanPreviewController(player: player, access: access)
      : null;
  addTearDown(() async {
    final gate = source.cancelGate;
    if (gate != null && !gate.isCompleted) gate.complete();
    final pendingScan = source.scanGate;
    if (pendingScan != null && !pendingScan.isCompleted) pendingScan.complete();
    if (audio.stopGate != null && !audio.stopGate!.isCompleted) {
      audio.stopGate!.complete();
    }
    await tester.pumpWidget(const SizedBox());
    await preview?.close();
    final playerClosing = player.close();
    await tester.pump();
    await playerClosing;
    await library.close();
    repository.close();
    await tester.runAsync(() => root.delete(recursive: true));
  });
  Widget page() => MediaScanPage(
    library: library,
    source: source,
    android: android,
    scanPreview: preview,
    canPreview: canPreview,
    sourceActions: actions,
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: hemingTheme(brightness, mobile: size.width < 860),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(
          context,
        ).copyWith(textScaler: TextScaler.linear(textScale)),
        child: child!,
      ),
      home: route
          ? Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute<String>(builder: (_) => page()),
                  ),
                  child: const Text('打开扫描'),
                ),
              ),
            )
          : page(),
    ),
  );
  await tester.pumpAndSettle();
  if (route) await _tap(tester, find.text('打开扫描'));
  expect(source.permissionRequests, [true]);
  expect(source.excludedRoots.single, [root.path]);
  return _Harness(library, source, preview, audio, access, actions);
}

Finder _tile(String name) =>
    find.ancestor(of: find.text(name), matching: find.byType(CheckboxListTile));

Future<void> _tap(WidgetTester tester, Finder finder) async {
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('audio preview controls never select or import a source', (
    tester,
  ) async {
    final harness = await _mount(tester, withPreview: true);
    await _tap(tester, find.byKey(const ValueKey('preview-audio-a')));
    expect(harness.preview!.state, PreviewState.playing);
    expect(harness.audio.opened, ['audio-a.wav']);
    expect(harness.library.imports, isEmpty);
    expect(find.textContaining('已选 0 项'), findsOneWidget);
    expect(find.byKey(const ValueKey('scan-preview-strip')), findsOneWidget);

    await _tap(tester, find.byKey(const ValueKey('scan-preview-toggle')));
    expect(harness.preview!.state, PreviewState.paused);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('scan-preview-seek')),
    );
    slider.onChanged!(30000);
    slider.onChangeEnd!(30000);
    await tester.pumpAndSettle();
    expect(harness.preview!.positionMs, 30000);
    await _tap(tester, find.byKey(const ValueKey('scan-preview-toggle')));
    expect(harness.preview!.state, PreviewState.playing);

    await _tap(tester, find.byKey(const ValueKey('preview-audio-b')));
    expect(harness.preview!.entry!.sourceId, 'audio-b');
    expect(harness.audio.opened, ['audio-a.wav', 'audio-b.wav']);
    expect(harness.access.released, 1);
    await _tap(tester, _tile('audio-a.mp3'));
    await _tap(tester, find.byKey(const ValueKey('scan-preview-close')));
    expect(harness.preview!.isActive, isFalse);
    expect(find.byKey(const ValueKey('scan-preview-strip')), findsNothing);
    expect(find.textContaining('已选 1 项'), findsOneWidget);
    expect(harness.library.imports, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('imported audio still previews and video only opens externally', (
    tester,
  ) async {
    final existing = _entry('existing');
    final harness = await _mount(
      tester,
      withPreview: true,
      entries: [existing, _entry('video', video: true)],
      imported: {existing.sourceKey},
    );
    expect(
      tester.widget<CheckboxListTile>(_tile('existing.mp3')).onChanged,
      isNull,
    );
    await _tap(tester, find.byKey(const ValueKey('preview-existing')));
    expect(harness.preview!.state, PreviewState.playing);
    expect(find.byKey(const ValueKey('preview-video')), findsNothing);
    await _tap(tester, find.byKey(const ValueKey('source-actions-video')));
    await _tap(tester, find.text('用其他播放器打开'));
    expect(harness.actions.opened.single.category, 'video');
    expect(harness.preview!.isActive, isFalse);
    expect(harness.access.prepared.map((entry) => entry.sourceId), [
      'existing',
    ]);
    expect(harness.library.imports, isEmpty);
    expect(find.textContaining('已选 0 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('starting import stops preview before copying selected media', (
    tester,
  ) async {
    final harness = await _mount(tester, withPreview: true);
    await _tap(tester, find.byKey(const ValueKey('preview-audio-a')));
    await _tap(tester, _tile('audio-b.mp3'));
    harness.library.beforeImport = () {
      expect(harness.preview!.isActive, isFalse);
      expect(harness.access.released, 1);
    };
    await _tap(tester, find.text('加入资源库'));
    expect(harness.library.imports.single.single.sourceId, 'audio-b');
    expect(find.byKey(const ValueKey('scan-preview-strip')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'background and returning from scan stop preview and keep choices',
    (tester) async {
      final harness = await _mount(tester, withPreview: true, route: true);
      await _tap(tester, _tile('audio-b.mp3'));
      await _tap(tester, find.byKey(const ValueKey('preview-audio-a')));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await tester.pumpAndSettle();
      expect(harness.preview!.isActive, isFalse);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(find.textContaining('已选 1 项'), findsOneWidget);
      await _tap(tester, find.byKey(const ValueKey('preview-audio-a')));
      await _tap(tester, find.byTooltip('返回资源库'));
      expect(harness.preview!.isActive, isFalse);
      expect(find.text('打开扫描'), findsOneWidget);
      expect(harness.library.imports, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('group state disables playback while retaining file reveal', (
    tester,
  ) async {
    final harness = await _mount(tester, withPreview: true, canPreview: false);
    final button = tester.widget<IconButton>(
      find.byKey(const ValueKey('preview-audio-a')),
    );
    expect(button.onPressed, isNull);
    await _tap(tester, find.byKey(const ValueKey('source-actions-audio-a')));
    final external = tester.widget<PopupMenuItem<String>>(
      find.widgetWithText(PopupMenuItem<String>, '用其他播放器打开'),
    );
    expect(external.enabled, isFalse);
    await _tap(tester, find.text('在文件夹中显示'));
    expect(harness.actions.revealed.single.sourceId, 'audio-a');
    expect(harness.audio.opened, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'external launch pending on stop is cancelled when backgrounded',
    (tester) async {
      final harness = await _mount(tester, withPreview: true);
      await _tap(tester, find.byKey(const ValueKey('preview-audio-a')));
      harness.audio.stopGate = Completer<void>();
      await _tap(tester, find.byKey(const ValueKey('source-actions-video')));
      await tester.tap(find.text('用其他播放器打开'));
      await tester.pump();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      harness.audio.stopGate!.complete();
      await tester.pumpAndSettle();
      expect(harness.actions.opened, isEmpty);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(harness.actions.opened, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'active preview fits narrow dark large-text layout with keyboard',
    (tester) async {
      final harness = await _mount(
        tester,
        withPreview: true,
        android: true,
        size: const Size(320, 568),
        textScale: 1.6,
        brightness: Brightness.dark,
        entries: [_entry('很长很长的音乐名称，用来检查试听播放条和列表')],
      );
      await _tap(
        tester,
        find.byKey(const ValueKey('preview-很长很长的音乐名称，用来检查试听播放条和列表')),
      );
      expect(harness.preview!.state, PreviewState.playing);
      expect(tester.takeException(), isNull);
      await _tap(tester, find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 230);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '音乐');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('scan-preview-strip')), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byKey(const ValueKey('scan-preview-close')));
      await tester.pumpAndSettle();
      expect(harness.preview!.isActive, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selection and inversion affect only the visible filter', (
    tester,
  ) async {
    final harness = await _mount(tester);
    await _tap(tester, find.text('音频'));
    await _tap(tester, find.text('全选当前列表'));
    expect(find.textContaining('已选 2 项'), findsOneWidget);

    await _tap(tester, find.text('视频'));
    await _tap(tester, find.text('反选'));
    expect(find.textContaining('已选 3 项'), findsOneWidget);
    await _tap(tester, find.text('反选'));
    expect(find.textContaining('已选 2 项'), findsOneWidget);

    await _tap(tester, find.text('全部'));
    await tester.enterText(find.byType(TextField), 'audio-a');
    await tester.pumpAndSettle();
    await _tap(tester, find.text('反选'));
    expect(find.textContaining('已选 1 项'), findsOneWidget);
    await _tap(tester, find.text('加入资源库'));
    expect(harness.library.imports.single.map((entry) => entry.sourceId), [
      'audio-b',
    ]);
    expect(find.text('已加入 1 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'already imported sources are disabled and excluded from select all',
    (tester) async {
      final existing = _entry('existing');
      final harness = await _mount(
        tester,
        entries: [existing, _entry('new')],
        imported: {existing.sourceKey},
      );
      final existingTile = tester.widget<CheckboxListTile>(
        _tile('existing.mp3'),
      );
      expect(existingTile.onChanged, isNull);
      expect(existingTile.value, isFalse);
      expect(find.textContaining('已加入'), findsOneWidget);
      await _tap(tester, find.text('全选当前列表'));
      expect(find.textContaining('已选 1 项'), findsOneWidget);
      await _tap(tester, find.text('加入资源库'));
      expect(harness.library.imports.single.map((entry) => entry.sourceId), [
        'new',
      ]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('selected target group and selected sources reach the import', (
    tester,
  ) async {
    final harness = await _mount(tester, createGroup: true);
    await _tap(tester, _tile('audio-a.mp3'));
    await _tap(tester, find.byType(DropdownButtonFormField<String>));
    await _tap(tester, find.text('夜间音乐').last);
    await _tap(tester, find.text('加入资源库'));
    expect(harness.library.targetGroup, harness.library.groups.single.id);
    expect(harness.library.imports.single.map((entry) => entry.sourceId), [
      'audio-a',
    ]);
    expect(find.textContaining('已选 0 项'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'rapid add taps do not start another import while scan cancellation waits',
    (tester) async {
      final harness = await _mount(tester);
      await _tap(tester, _tile('audio-a.mp3'));
      final gate = Completer<void>();
      harness.source.cancelGate = gate;
      final add = find.text('加入资源库');
      await tester.tap(add);
      // No frame between taps: both hit the previously rendered button.
      await tester.tap(add);
      expect(harness.library.imports, isEmpty);
      gate.complete();
      await tester.pumpAndSettle();
      expect(harness.library.imports, hasLength(1));
      expect(find.text('已加入 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'stopping during scan shutdown does not begin the pending import',
    (tester) async {
      final harness = await _mount(tester);
      await _tap(tester, _tile('audio-a.mp3'));
      final gate = Completer<void>();
      harness.source.cancelGate = gate;
      await tester.tap(find.text('加入资源库'));
      await tester.pump();
      await tester.tap(find.text('停止添加'));
      gate.complete();
      await tester.pumpAndSettle();
      expect(harness.library.imports, isEmpty);
      expect(find.text('加入资源库'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'partial access is visible and resume refreshes without requesting permissions',
    (tester) async {
      final harness = await _mount(
        tester,
        android: true,
        audioAccess: 'denied',
        videoAccess: 'partial',
        entries: [_entry('allowed-video', video: true)],
      );
      expect(find.textContaining('音频尚未授权。'), findsOneWidget);
      expect(find.textContaining('仅显示已授权的视频。'), findsOneWidget);
      await _tap(tester, _tile('allowed-video.mp4'));
      expect(find.textContaining('已选 1 项'), findsOneWidget);

      harness.source.entries = [];
      harness.source.videoAccess = 'denied';
      for (final state in [
        AppLifecycleState.inactive,
        AppLifecycleState.hidden,
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        tester.binding.handleAppLifecycleStateChanged(state);
      }
      await tester.pumpAndSettle();
      expect(harness.source.permissionRequests, [true, false]);
      expect(find.text('allowed-video.mp4'), findsNothing);
      expect(find.textContaining('已选 0 项'), findsOneWidget);
      expect(find.textContaining('视频尚未授权。'), findsOneWidget);
      await _tap(tester, find.text('调整授权'));
      expect(harness.source.permissionRequests, [true, false, true]);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'resume during an active scan schedules one permission-free refresh after it finishes',
    (tester) async {
      final harness = await _mount(
        tester,
        android: true,
        entries: [_entry('previously-allowed', video: true)],
      );
      await _tap(tester, _tile('previously-allowed.mp4'));
      final pending = Completer<void>();
      harness.source.scanGate = pending;
      await tester.tap(find.text('重新扫描'));
      await tester.pump();
      expect(harness.source.permissionRequests, [true, false]);

      // The in-flight request already captured the old permission scope.
      harness.source.entries = [];
      harness.source.videoAccess = 'denied';
      for (var cycle = 0; cycle < 2; cycle++) {
        for (final state in [
          AppLifecycleState.inactive,
          AppLifecycleState.hidden,
          AppLifecycleState.paused,
          AppLifecycleState.hidden,
          AppLifecycleState.inactive,
          AppLifecycleState.resumed,
        ]) {
          tester.binding.handleAppLifecycleStateChanged(state);
        }
      }
      await tester.pump();
      // Resume events are coalesced; the current scan is allowed to finish.
      expect(harness.source.permissionRequests, [true, false]);
      pending.complete();
      await tester.pumpAndSettle();
      expect(harness.source.permissionRequests, [true, false, false]);
      expect(find.text('previously-allowed.mp4'), findsNothing);
      expect(find.textContaining('视频尚未授权。'), findsOneWidget);
      expect(find.textContaining('已选 0 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'small dark layout with large text remains usable with the search keyboard',
    (tester) async {
      await _mount(
        tester,
        android: true,
        size: const Size(320, 568),
        textScale: 1.6,
        brightness: Brightness.dark,
        entries: [
          _entry('这是一首名称很长的音乐，用来检查窄屏换行'),
          _entry('演出现场的视频', video: true),
        ],
      );
      expect(tester.takeException(), isNull);
      await _tap(tester, find.byType(TextField));
      tester.view.viewInsets = const FakeViewPadding(bottom: 230);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '音乐');
      await tester.pumpAndSettle();
      await tester.scrollUntilVisible(
        find.text('加入资源库'),
        120,
        scrollable: find
            .descendant(
              of: find.byType(CustomScrollView),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(find.text('加入资源库'), findsOneWidget);
      expect(tester.takeException(), isNull);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      await _tap(tester, find.text('全选当前列表'));
      expect(find.textContaining('已选 1 项'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
