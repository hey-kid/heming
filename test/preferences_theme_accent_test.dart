import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/preferences.dart';
import 'package:heming/app/theme_accent.dart';
import 'package:heming/data/library_repository.dart';

void main() {
  test(
    'theme color survives repository reopen without changing other preferences',
    () async {
      final root = await Directory.systemTemp.createTemp('heming-accent-');
      var repository = await LibraryRepository.open(root);
      var preferences = Preferences(repository);
      try {
        expect(preferences.themeAccent, ThemeAccent.forest);
        repository.setSetting('deviceName', '客厅电脑');
        repository.setSetting('volume', '0.35');
        preferences.setTheme(ThemeMode.dark);
        preferences.setThemeAccent(ThemeAccent.mist);
        preferences.dispose();
        repository.close();
        repository = await LibraryRepository.open(root);
        preferences = Preferences(repository);
        expect(preferences.themeAccent, ThemeAccent.mist);
        expect(preferences.themeMode, ThemeMode.dark);
        expect(repository.setting('deviceName'), '客厅电脑');
        expect(repository.setting('volume'), '0.35');
      } finally {
        preferences.dispose();
        repository.close();
        await root.delete(recursive: true);
      }
    },
  );

  test('unknown saved color safely falls back and can be replaced', () async {
    final root = await Directory.systemTemp.createTemp(
      'heming-accent-fallback-',
    );
    final repository = await LibraryRepository.open(root);
    repository.setSetting('themeAccent', 'future-color');
    final preferences = Preferences(repository);
    try {
      expect(preferences.themeAccent, ThemeAccent.forest);
      preferences.setThemeAccent(ThemeAccent.lilac);
      expect(repository.setting('themeAccent'), 'lilac');
      expect(preferences.themeAccent, ThemeAccent.lilac);
    } finally {
      preferences.dispose();
      repository.close();
      await root.delete(recursive: true);
    }
  });
}
