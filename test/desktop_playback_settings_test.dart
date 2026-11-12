import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/preferences.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/features/playback/playback_page.dart';
import 'package:heming/features/settings/settings_page.dart';
import 'package:heming/session/session_controller.dart';

import 'app_layout_test.dart' show NoAudio, NoMedia;

class _DesktopSession extends SessionController {
  _DesktopSession()
    : super(audio: NoAudio(), deviceId: 'desktop', deviceName: '书房电脑');

  static const track = PlayableTrack(
    id: 'current',
    title: '当前歌曲',
    path: 'song.flac',
    durationMs: 120000,
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

Widget _desktopApp(Widget child, double contentWidth) => MaterialApp(
  theme: hemingTheme(Brightness.dark),
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(1.4)),
    child: child!,
  ),
  home: Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: contentWidth,
        child: SingleChildScrollView(
          key: const PageStorageKey('desktop-page-scroll'),
          child: child,
        ),
      ),
    ),
  ),
);

void main() {
  for (final contentWidth in [584.0, 1160.0]) {
    testWidgets(
      'desktop playback adapts at $contentWidth with accessible controls',
      (tester) async {
        tester.view.physicalSize = const Size(1440, 960);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final session = _DesktopSession();
        var libraryOpened = 0;
        await tester.pumpWidget(
          _desktopApp(
            PlaybackPage(
              session: session,
              selectLibrary: () => libraryOpened++,
            ),
            contentWidth,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(find.text('书房电脑'), findsNothing);
        final stop = tester.getSize(find.byKey(const ValueKey('desktop-stop')));
        expect(stop.width, greaterThanOrEqualTo(48));
        for (final key in [
          'desktop-previous',
          'desktop-next',
          'desktop-library',
        ]) {
          expect(tester.getSize(find.byKey(ValueKey(key))), stop);
        }
        final semantics = tester.ensureSemantics();
        try {
          await tester.pump();
          expect(find.bySemanticsLabel('结束播放'), findsOneWidget);
          expect(find.bySemanticsLabel('切换资源'), findsOneWidget);
        } finally {
          semantics.dispose();
        }
        await tester.tap(find.byTooltip('切换资源'));
        await tester.pumpAndSettle();
        expect(libraryOpened, 1);
        if (contentWidth < 860) {
          expect(
            tester.getTopLeft(find.text('本次播放列表')).dy,
            lessThan(tester.getTopLeft(find.text('参与设备')).dy),
          );
        } else {
          expect(
            tester.getTopLeft(find.text('本次播放列表')).dx,
            lessThan(tester.getTopLeft(find.text('参与设备')).dx),
          );
        }
        await tester.ensureVisible(find.text('参与设备'));
        await tester.tap(find.text('参与设备'));
        await tester.pumpAndSettle();
        expect(find.text('书房电脑'), findsOneWidget);
        await tester.ensureVisible(find.text('连接与缓冲详情'));
        await tester.tap(find.text('连接与缓冲详情'));
        await tester.pumpAndSettle();
        expect(find.text('本机缓冲'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox());
        await session.shutdown();
      },
    );
  }

  testWidgets('desktop settings retain name and appearance persistence', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 960);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    late Directory root;
    late LibraryRepository repository;
    await tester.runAsync(() async {
      root = await Directory.systemTemp.createTemp('heming-desktop-settings-');
      repository = await LibraryRepository.open(root);
    });
    final library = LibraryController(repository: repository, media: NoMedia());
    final session = SessionController(
      audio: NoAudio(),
      deviceId: 'desktop',
      deviceName: '书房电脑',
    );
    final preferences = Preferences(repository);
    for (final contentWidth in [584.0, 1160.0]) {
      await tester.pumpWidget(
        _desktopApp(
          ListenableBuilder(
            listenable: preferences,
            builder: (context, _) => SettingsPage(
              session: session,
              library: library,
              preferences: preferences,
            ),
          ),
          contentWidth,
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('目标缓冲'), findsNothing);
      expect(tester.takeException(), isNull);
    }
    await tester.enterText(find.byType(TextField), '  ');
    await tester.tap(find.text('保存名称'));
    await tester.pumpAndSettle();
    expect(session.localDevice.name, '书房电脑');
    expect(find.textContaining('设备名称不能为空'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  客厅电脑  ');
    await tester.tap(find.text('保存名称'));
    await tester.pumpAndSettle();
    expect(session.localDevice.name, '客厅电脑');
    expect(repository.setting('deviceName'), '客厅电脑');
    await tester.tap(find.text('深色'));
    await tester.pumpAndSettle();
    expect(repository.setting('themeMode'), 'dark');
    await tester.ensureVisible(find.text('资源与播放'));
    await tester.tap(find.text('资源与播放'));
    await tester.pumpAndSettle();
    expect(find.text('目标缓冲'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox());
    await session.shutdown();
    library.dispose();
    preferences.dispose();
    repository.close();
    await tester.runAsync(() => root.delete(recursive: true));
  });
}
