import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/features/playback/playback_page.dart';
import 'package:heming/session/session_controller.dart';

class _NoAudio extends AudioSessionPort {
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

class _PlayingSession extends SessionController {
  _PlayingSession()
    : super(audio: _NoAudio(), deviceId: 'local', deviceName: '电脑');

  static const track = PlayableTrack(
    id: 'track',
    title: '测试歌曲',
    path: 'sample.flac',
    durationMs: 2998000,
  );
  @override
  SessionPhase get phase => SessionPhase.playing;
  @override
  bool get isMaster => true;
  @override
  PlayableTrack? get currentTrack => track;
  @override
  List<PlayableTrack> get queue => [track];
  @override
  int get queueIndex => 0;
  @override
  List<DeviceMember> get members => [localDevice];
}

class _QueueSession extends _PlayingSession {
  _QueueSession({this.master = true});
  final bool master;
  int selectedIndex = 0;
  PlaybackMode mode = PlaybackMode.sequential;
  @override
  bool get isMaster => master;
  @override
  int get queueIndex => selectedIndex;
  @override
  List<PlayableTrack> get queue => [
    _PlayingSession.track,
    const PlayableTrack(
      id: 'second',
      title: '第二首很长的歌曲名称用于窄屏换行检查',
      path: 'b.flac',
      durationMs: 123000,
    ),
  ];
  @override
  bool get canNextTrack => master && selectedIndex == 0;
  @override
  bool get canPreviousTrack => master && selectedIndex == 1;
  @override
  PlaybackMode get playbackMode => mode;
  @override
  bool get modeChangePending => mode == PlaybackMode.random;
  @override
  Future<void> nextTrack() => selectQueueTrack(1);
  @override
  Future<void> previousTrack() => selectQueueTrack(0);
  @override
  Future<void> selectQueueTrack(int index) async {
    selectedIndex = index;
    notifyListeners();
  }

  @override
  void setPlaybackMode(PlaybackMode value) {
    mode = value;
    notifyListeners();
  }
}

class _IdleSession extends _QueueSession {
  _IdleSession({super.master});
  @override
  PlayableTrack? get currentTrack => null;
  @override
  SessionPhase get phase => SessionPhase.standby;
}

void main() {
  for (final master in [true, false]) {
    testWidgets('mobile idle player keeps full page width for master=$master', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final session = _IdleSession(master: master);
      await tester.pumpWidget(
        MaterialApp(
          theme: hemingTheme(Brightness.light, mobile: true),
          home: Scaffold(
            body: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Align(
                alignment: Alignment.topCenter,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 1080),
                  child: PlaybackPage(session: session, selectLibrary: () {}),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('mobile-player-empty'))).width,
        320,
      );
      expect(tester.getTopLeft(find.text('正在播放')).dx, 20);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox());
      await session.shutdown();
    });
  }
  for (final width in [320.0, 1280.0]) {
    for (final master in [true, false]) {
      testWidgets(
        'queue controls fit $width px and ${master ? 'master controls' : 'follower reads'}',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          final session = _QueueSession(master: master);
          await tester.pumpWidget(
            MaterialApp(
              theme: hemingTheme(Brightness.light),
              home: Scaffold(
                body: SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: ListenableBuilder(
                    listenable: session,
                    builder: (context, _) =>
                        PlaybackPage(session: session, selectLibrary: () {}),
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
          if (master) {
            final next = find.byTooltip('下一首');
            final previous = find.byTooltip('上一首');
            await tester.ensureVisible(next);
            await tester.tap(next);
            await tester.pumpAndSettle();
            expect(session.queueIndex, 1);
            await tester.tap(previous);
            await tester.pumpAndSettle();
            expect(session.queueIndex, 0);
            await tester.ensureVisible(find.text('随机播放'));
            await tester.tap(find.text('随机播放'));
            await tester.pumpAndSettle();
            expect(session.playbackMode, PlaybackMode.random);
            expect(find.text('下一首生效 · 随机播放'), findsOneWidget);
            await tester.ensureVisible(
              find.byKey(const ValueKey('queue-track-1')),
            );
            await tester.tap(find.byKey(const ValueKey('queue-track-1')));
            await tester.pumpAndSettle();
            expect(session.queueIndex, 1);
          } else {
            expect(find.text('上一首'), findsNothing);
            expect(find.text('下一首'), findsNothing);
            expect(find.byTooltip('上一首'), findsNothing);
            expect(find.byTooltip('下一首'), findsNothing);
            expect(find.byType(ChoiceChip), findsNothing);
            final row = tester.widget<InkWell>(
              find.byKey(const ValueKey('queue-track-1')),
            );
            expect(row.onTap, isNull);
          }
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox());
          await session.shutdown();
        },
      );
    }
  }
  for (final expandDetails in [false, true]) {
    testWidgets(
      'playback survives scroll and navigation with details ${expandDetails ? 'expanded' : 'collapsed'}',
      (tester) async {
        final session = _PlayingSession();
        final bucket = PageStorageBucket();
        var showing = true;
        late StateSetter update;
        await tester.pumpWidget(
          MaterialApp(
            theme: hemingTheme(Brightness.light),
            home: StatefulBuilder(
              builder: (context, setState) {
                update = setState;
                return Scaffold(
                  body: PageStorage(
                    bucket: bucket,
                    child: showing
                        ? SingleChildScrollView(
                            // Match the app shell's persisted per-page scroll.
                            key: const PageStorageKey('page-2'),
                            child: PlaybackPage(
                              session: session,
                              selectLibrary: () {},
                            ),
                          )
                        : const Text('其他页面'),
                  ),
                );
              },
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.ensureVisible(find.text('连接与缓冲详情'));
        await tester.pumpAndSettle();
        if (expandDetails) {
          await tester.tap(find.text('连接与缓冲详情'));
          await tester.pumpAndSettle();
          // Saving a new scroll offset must not overwrite expansion state.
          await tester.drag(
            find.byType(SingleChildScrollView),
            const Offset(0, -100),
          );
          await tester.pumpAndSettle();
        }
        final offset = tester
            .state<ScrollableState>(find.byType(Scrollable))
            .position
            .pixels;
        expect(offset, greaterThan(0));
        expect(tester.takeException(), isNull);
        update(() => showing = false);
        await tester.pumpAndSettle();
        update(() => showing = true);
        await tester.pumpAndSettle();

        expect(tester.takeException(), isNull);
        expect(find.byType(ErrorWidget), findsNothing);
        expect(find.text('本次播放列表'), findsOneWidget);
        expect(find.text('测试歌曲'), findsNWidgets(2));
        expect(
          tester
              .state<ScrollableState>(find.byType(Scrollable))
              .position
              .pixels,
          closeTo(offset, 0.01),
        );
        expect(
          find.text('本机缓冲'),
          expandDetails ? findsOneWidget : findsNothing,
        );
        await tester.pumpWidget(const SizedBox());
        await session.shutdown();
      },
    );
  }

  for (final configuration in [
    (360.0, 1.15, Brightness.light),
    (320.0, 1.6, Brightness.dark),
  ]) {
    testWidgets(
      'mobile player groups controls and keeps devices collapsed at $configuration',
      (tester) async {
        tester.view.physicalSize = Size(configuration.$1, 820);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final session = _QueueSession();
        await tester.pumpWidget(
          MaterialApp(
            theme: hemingTheme(configuration.$3, mobile: true),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(configuration.$2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: PlaybackPage(session: session, selectLibrary: () {}),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        final stop = tester.getSize(find.byKey(const ValueKey('mobile-stop')));
        expect(stop.width, greaterThanOrEqualTo(48));
        expect(stop.height, greaterThanOrEqualTo(48));
        for (final key in [
          'mobile-previous',
          'mobile-next',
          'mobile-library',
        ]) {
          expect(tester.getSize(find.byKey(ValueKey(key))), stop);
        }
        final semantics = tester.ensureSemantics();
        try {
          await tester.pump();
          for (final label in ['上一首', '下一首', '结束播放', '切换资源']) {
            expect(find.text(label), findsNothing);
            expect(find.byTooltip(label), findsOneWidget);
            expect(find.bySemanticsLabel(label), findsOneWidget);
          }
        } finally {
          semantics.dispose();
        }
        await tester.longPress(find.byTooltip('结束播放'));
        await tester.pumpAndSettle();
        expect(find.text('结束播放'), findsOneWidget);
        await tester.pump(const Duration(seconds: 2));
        await tester.pumpAndSettle();
        expect(
          tester.getTopLeft(find.text('本次播放列表')).dy,
          lessThan(tester.getTopLeft(find.text('参与设备')).dy),
        );
        expect(find.text('电脑'), findsNothing);
        await tester.ensureVisible(find.text('参与设备'));
        await tester.tap(find.text('参与设备'));
        await tester.pumpAndSettle();
        expect(find.text('电脑'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await session.shutdown();
      },
    );
  }
}
