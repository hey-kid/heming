import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/preferences.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/features/settings/settings_page.dart';
import 'package:heming/session/session_controller.dart';

import 'app_layout_test.dart' show NoAudio, NoMedia;

Future<
  ({
    SessionController session,
    Preferences preferences,
    LibraryRepository repository,
  })
>
_showSettings(
  WidgetTester tester, {
  required double width,
  required double scale,
  required ThemeMode themeMode,
}) async {
  tester.view.physicalSize = Size(width, 780);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  late Directory root;
  late LibraryRepository repository;
  await tester.runAsync(() async {
    root = await Directory.systemTemp.createTemp('heming-mobile-settings-');
    repository = await LibraryRepository.open(root);
    repository.setSetting('themeMode', themeMode.name);
  });
  final library = LibraryController(repository: repository, media: NoMedia());
  final preferences = Preferences(repository);
  final session = SessionController(
    audio: NoAudio(),
    deviceId: 'phone',
    deviceName: '客厅手机',
    platformName: 'Android',
  );
  addTearDown(() async {
    await tester.pumpWidget(const SizedBox());
    await session.shutdown();
    library.dispose();
    preferences.dispose();
    repository.close();
    await tester.runAsync(() => root.delete(recursive: true));
  });
  await tester.pumpWidget(
    AnimatedBuilder(
      animation: preferences,
      builder: (context, _) => MaterialApp(
        theme: hemingTheme(Brightness.light, mobile: true),
        darkTheme: hemingTheme(Brightness.dark, mobile: true),
        themeMode: preferences.themeMode,
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: SingleChildScrollView(
            key: const PageStorageKey('mobile-settings-test-scroll'),
            padding: const EdgeInsets.all(16),
            child: SettingsPage(
              session: session,
              library: library,
              preferences: preferences,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return (session: session, preferences: preferences, repository: repository);
}

void main() {
  testWidgets(
    'mobile settings preserve name validation and appearance saving',
    (tester) async {
      final fixture = await _showSettings(
        tester,
        width: 360,
        scale: 1.15,
        themeMode: ThemeMode.light,
      );
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(find.textContaining('设备名称不能为空'), findsOneWidget);
      expect(fixture.session.localDevice.name, '客厅手机');
      expect(fixture.repository.setting('deviceName'), isNull);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '  卧室音箱  ');
      await tester.tap(find.text('保存名称'));
      await tester.pumpAndSettle();
      expect(fixture.session.localDevice.name, '卧室音箱');
      expect(fixture.repository.setting('deviceName'), '卧室音箱');

      await tester.ensureVisible(find.text('深色'));
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      expect(fixture.preferences.themeMode, ThemeMode.dark);
      expect(fixture.repository.setting('themeMode'), 'dark');
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'narrow dark settings keep playback details collapsed and readable',
    (tester) async {
      await _showSettings(
        tester,
        width: 320,
        scale: 1.4,
        themeMode: ThemeMode.dark,
      );
      expect(tester.takeException(), isNull);
      expect(find.text('目标缓冲'), findsNothing);
      await tester.ensureVisible(find.text('资源与播放'));
      await tester.tap(find.text('资源与播放'));
      await tester.pumpAndSettle();
      expect(find.text('目标缓冲'), findsOneWidget);
      expect(find.text('5 秒'), findsOneWidget);
      expect(find.text('最多 6 台设备'), findsOneWidget);
      await tester.ensureVisible(find.text('Windows / Android'));
      expect(tester.takeException(), isNull);
    },
  );
}
