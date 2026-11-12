import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/heming_app.dart';
import 'package:heming/app/preferences.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_models.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/preview/preview_controller.dart';
import 'package:heming/session/session_controller.dart';

import 'app_layout_test.dart' show NoAudio, NoMedia;
import 'preview_controller_test.dart' show FakePreviewAudio;

class _RecordingSession extends SessionController {
  _RecordingSession(this.journal, {required this.connected})
    : super(audio: NoAudio(), deviceId: 'local', deviceName: '测试电脑');
  final List<String> journal;
  bool connected;
  List<PlayableTrack> receivedTracks = [];
  int receivedStartIndex = 0;
  int playlistCalls = 0;
  @override
  bool get isConnected => connected;
  @override
  bool get isMaster => connected;
  @override
  SessionPhase get phase => currentTrack != null
      ? SessionPhase.playing
      : connected
      ? SessionPhase.standby
      : SessionPhase.disconnected;
  @override
  List<PlayableTrack> get queue => receivedTracks;
  @override
  int get queueIndex => receivedStartIndex;
  @override
  PlayableTrack? get currentTrack =>
      receivedTracks.isEmpty ? null : receivedTracks[receivedStartIndex];
  @override
  List<DeviceMember> get members => connected ? [localDevice] : [];
  @override
  Future<void> createRoom() async {
    journal.add('create-room');
    connected = true;
    notifyListeners();
  }

  @override
  Future<void> startPlaylist(
    List<PlayableTrack> tracks, {
    int startIndex = 0,
  }) async {
    journal.add('start-playlist');
    receivedTracks = List.unmodifiable(tracks);
    receivedStartIndex = startIndex;
    playlistCalls++;
    notifyListeners();
  }
}

class _Fixture {
  _Fixture(
    this.root,
    this.repository,
    this.library,
    this.preferences,
    this.session,
    this.previewAudio,
    this.preview,
    this.journal,
  );
  final Directory root;
  final LibraryRepository repository;
  final LibraryController library;
  final Preferences preferences;
  final _RecordingSession session;
  final FakePreviewAudio previewAudio;
  final PreviewController preview;
  final List<String> journal;

  static Future<_Fixture> open({required bool connected}) async {
    final root = await Directory.systemTemp.createTemp('heming-app-playback-');
    final repository = await LibraryRepository.open(root);
    final source = await File(
      '${root.path}/sample.flac',
    ).writeAsBytes([1, 2, 3]);
    repository.saveGroup(const LibraryGroup(id: 'group', name: '测试分组'));
    for (var i = 0; i < 6; i++) {
      repository.save(
        LibraryItem(
          id: 'item-$i',
          title: i == 4
              ? '独立歌曲'
              : i == 5
              ? '额外歌曲'
              : '分组歌曲 $i',
          originalPath: source.path,
          originalName: 'sample.flac',
          status: i == 1 ? LibraryStatus.needsConversion : LibraryStatus.ready,
          importedAt: DateTime(2026, 11, 11).add(Duration(seconds: i)),
          playablePath: i == 1 ? null : source.path,
          groupId: i >= 4 ? null : 'group',
          groupOrder: i,
          metadata: const AudioMetadata(
            codec: 'flac',
            sampleRate: 48000,
            channels: 2,
            bitsPerSample: 16,
            durationMs: 10000,
            verified: true,
          ),
        ),
      );
    }
    final library = LibraryController(repository: repository, media: NoMedia());
    await library.initialize();
    final journal = <String>[];
    final session = _RecordingSession(journal, connected: connected);
    final previewAudio = FakePreviewAudio();
    final preview = PreviewController(
      audio: previewAudio,
      canPlay: () => !session.isConnected && !session.isJoining,
      acquireFocus: () async {
        journal.add('preview-acquire');
        return true;
      },
      releaseFocus: () async {
        journal.add('preview-release');
      },
    );
    return _Fixture(
      root,
      repository,
      library,
      Preferences(repository),
      session,
      previewAudio,
      preview,
      journal,
    );
  }

  Future<void> close() async {
    await preview.close();
    await session.shutdown();
    await library.close();
    preferences.dispose();
    repository.close();
    await root.delete(recursive: true);
  }
}

Future<void> _show(WidgetTester tester, _Fixture fixture) async {
  tester.view.physicalSize = const Size(1280, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  await tester.pumpWidget(
    HemingApp(
      session: fixture.session,
      library: fixture.library,
      preferences: fixture.preferences,
      preview: fixture.preview,
    ),
  );
  await tester.pumpAndSettle();
  await tester.tap(find.text('资源库').first);
  await tester.pumpAndSettle();
}

Future<void> _tapPlay(WidgetTester tester, String id) async {
  final button = find.descendant(
    of: find.byKey(ValueKey(id)),
    matching: find.text('播放'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
}

Future<void> _waitFor(WidgetTester tester, bool Function() predicate) async {
  for (var attempt = 0; attempt < 100 && !predicate(); attempt++) {
    // UI callbacks start in the test zone; pump their microtasks as real file
    // validation completes outside the fake clock.
    await tester.pump();
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 10)),
    );
  }
  expect(predicate(), isTrue);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
    'group row passes its full ordered group and original start index despite search filtering',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => _Fixture.open(connected: true),
      ))!;
      try {
        await _show(tester, fixture);
        await tester.enterText(find.byType(TextField), '分组歌曲 2');
        await tester.pumpAndSettle();
        expect(find.byKey(const ValueKey('item-0')), findsNothing);
        await _tapPlay(tester, 'item-2');
        await _waitFor(tester, () => fixture.session.playlistCalls == 1);
        expect(fixture.session.receivedTracks.map((track) => track.id), [
          'item-0',
          'item-1',
          'item-2',
          'item-3',
        ]);
        expect(fixture.session.receivedStartIndex, 2);
        expect(fixture.session.receivedTracks[1].isPlayable, isFalse);
        expect(fixture.session.currentTrack?.id, 'item-2');
        expect(
          fixture.journal.indexOf('preview-release'),
          lessThan(fixture.journal.indexOf('start-playlist')),
        );
        expect(find.text('本次播放列表'), findsOneWidget);
        fixture.library.deleteGroup('group');
        expect(fixture.session.receivedTracks.map((track) => track.id), [
          'item-0',
          'item-1',
          'item-2',
          'item-3',
        ]);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'ungrouped row submits only itself instead of every visible resource',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => _Fixture.open(connected: true),
      ))!;
      try {
        await _show(tester, fixture);
        await _tapPlay(tester, 'item-4');
        await _waitFor(tester, () => fixture.session.playlistCalls == 1);
        expect(fixture.session.receivedTracks.map((track) => track.id), [
          'item-4',
        ]);
        expect(fixture.session.receivedStartIndex, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(fixture.close);
      }
    },
  );

  testWidgets(
    'local preview stops when leaving library and releases before room creation',
    (tester) async {
      final fixture = (await tester.runAsync(
        () => _Fixture.open(connected: false),
      ))!;
      try {
        await _show(tester, fixture);
        final previewButton = find.descendant(
          of: find.byKey(const ValueKey('item-4')),
          matching: find.text('试听'),
        );
        await tester.ensureVisible(previewButton);
        await tester.tap(previewButton);
        await _waitFor(
          tester,
          () => fixture.preview.state == PreviewState.playing,
        );
        expect(fixture.session.playlistCalls, 0);
        expect(fixture.session.isConnected, isFalse);
        expect(find.textContaining('本机试听 ·'), findsOneWidget);
        await tester.tap(find.text('设置').first);
        await tester.pumpAndSettle();
        expect(fixture.preview.isActive, isFalse);
        expect(fixture.previewAudio.status.state, PreviewState.idle);
        await tester.tap(find.text('资源库').first);
        await tester.pumpAndSettle();
        await tester.ensureVisible(previewButton);
        await tester.tap(previewButton);
        await _waitFor(
          tester,
          () => fixture.preview.state == PreviewState.playing,
        );
        await tester.tap(find.text('设备').first);
        await tester.pumpAndSettle();
        fixture.journal.clear();
        await tester.tap(find.text('创建播放组'));
        await _waitFor(tester, () => fixture.session.isConnected);
        expect(fixture.journal, ['preview-release', 'create-room']);
        expect(fixture.preview.isActive, isFalse);
        await tester.tap(find.text('资源库').first);
        await tester.pumpAndSettle();
        expect(find.text('试听'), findsNothing);
        expect(find.text('播放'), findsWidgets);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox());
        await tester.runAsync(fixture.close);
      }
    },
  );
}
