import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/heming_app.dart';
import 'package:heming/app/preferences.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/app/theme_accent.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/features/settings/settings_page.dart';
import 'package:heming/session/session_controller.dart';

import 'app_layout_test.dart' show NoAudio, NoMedia;

void main() {
  for (final width in [360.0, 1280.0]) {
    testWidgets('app applies accent immediately in both modes at $width', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late LibraryRepository repository;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('heming-app-accent-');
        repository = await LibraryRepository.open(root);
      });
      final preferences = Preferences(repository)..setTheme(ThemeMode.light);
      final library = LibraryController(
        repository: repository,
        media: NoMedia(),
      );
      final session = SessionController(
        audio: NoAudio(),
        deviceId: 'test',
        deviceName: '客厅设备',
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
        HemingApp(session: session, library: library, preferences: preferences),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('设置').last);
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '尚未保存的名称');
      await tester.ensureVisible(
        find.byKey(const ValueKey('theme-accent-mist')),
      );
      await tester.tap(find.byKey(const ValueKey('theme-accent-mist')));
      await tester.pumpAndSettle();
      final expectedLight = hemingTheme(
        Brightness.light,
        mobile: width < 860,
        accent: ThemeAccent.mist,
      );
      expect(
        Theme.of(tester.element(find.byType(SettingsPage))).colorScheme.primary,
        expectedLight.colorScheme.primary,
      );
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '尚未保存的名称',
      );
      expect(session.localDevice.name, '客厅设备');
      expect(preferences.themeAccent, ThemeAccent.mist);
      await tester.ensureVisible(find.text('深色'));
      await tester.tap(find.text('深色'));
      await tester.pumpAndSettle();
      final actual = Theme.of(tester.element(find.byType(SettingsPage)));
      expect(actual.brightness, Brightness.dark);
      expect(
        actual.colorScheme.primary,
        hemingTheme(
          Brightness.dark,
          accent: ThemeAccent.mist,
        ).colorScheme.primary,
      );
      expect(preferences.themeAccent, ThemeAccent.mist);
      expect(tester.takeException(), isNull);
    });
  }
}
