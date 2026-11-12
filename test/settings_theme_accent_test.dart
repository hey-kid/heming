import 'dart:io';
import 'dart:ui' show Tristate;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/preferences.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/app/theme_accent.dart';
import 'package:heming/app/theme_color_picker.dart';
import 'package:heming/data/library_controller.dart';
import 'package:heming/data/library_repository.dart';
import 'package:heming/features/settings/settings_page.dart';
import 'package:heming/session/session_controller.dart';

import 'app_layout_test.dart' show NoAudio, NoMedia;

void main() {
  for (final layout in [
    (320.0, 1.6, Brightness.dark),
    (1280.0, 1.0, Brightness.light),
  ]) {
    testWidgets('settings apply and save color choices at ${layout.$1}px', (
      tester,
    ) async {
      tester.view.physicalSize = Size(layout.$1, 820);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      late Directory root;
      late LibraryRepository repository;
      await tester.runAsync(() async {
        root = await Directory.systemTemp.createTemp('heming-theme-settings-');
        repository = await LibraryRepository.open(root);
      });
      final preferences = Preferences(repository)
        ..setThemeAccent(ThemeAccent.graphite);
      final library = LibraryController(
        repository: repository,
        media: NoMedia(),
      );
      final session = SessionController(
        audio: NoAudio(),
        deviceId: 'theme-test',
        deviceName: '原设备名称',
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
        ListenableBuilder(
          listenable: preferences,
          builder: (context, _) => MaterialApp(
            theme: hemingTheme(
              layout.$3,
              mobile: layout.$1 < 860,
              accent: preferences.themeAccent,
            ),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(layout.$2)),
              child: child!,
            ),
            home: Scaffold(
              body: SingleChildScrollView(
                padding: const EdgeInsets.all(20),
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
      final semantics = tester.ensureSemantics();
      try {
        for (final accent in ThemeAccent.values) {
          final choice = find.byKey(ValueKey('theme-accent-${accent.name}'));
          await tester.ensureVisible(choice);
          await tester.pumpAndSettle();
          expect(tester.getSize(choice).width, greaterThanOrEqualTo(48));
          expect(tester.getSize(choice).height, greaterThanOrEqualTo(48));
          await tester.tap(choice);
          await tester.pumpAndSettle();
          expect(preferences.themeAccent, accent);
          expect(repository.setting('themeAccent'), accent.name);
          expect(
            tester.getSemantics(choice).flagsCollection.isSelected,
            Tristate.isTrue,
          );
          expect(find.bySemanticsLabel(accent.label), findsOneWidget);
          expect(tester.takeException(), isNull);
        }
        expect(session.localDevice.name, '原设备名称');
        expect(preferences.themeMode, ThemeMode.system);
        final reloaded = Preferences(repository);
        expect(reloaded.themeAccent, ThemeAccent.graphite);
        reloaded.dispose();
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets('palette supports keyboard selection without a mouse', (
    tester,
  ) async {
    ThemeAccent? selection;
    await tester.pumpWidget(
      MaterialApp(
        theme: hemingTheme(Brightness.light),
        home: Scaffold(
          body: ThemeColorPicker(
            selected: ThemeAccent.graphite,
            onChanged: (value) => selection = value,
          ),
        ),
      ),
    );
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(selection, ThemeAccent.forest);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(selection, ThemeAccent.mist);
  });
}
