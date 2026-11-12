import 'package:flutter/material.dart';
import '../data/library_repository.dart';
import 'theme_accent.dart';

class Preferences extends ChangeNotifier {
  Preferences(this.repository)
    : themeMode = ThemeMode.values.firstWhere(
        (mode) => mode.name == repository.setting('themeMode'),
        orElse: () => ThemeMode.system,
      ),
      themeAccent = ThemeAccent.values.firstWhere(
        (accent) => accent.name == repository.setting('themeAccent'),
        orElse: () => ThemeAccent.forest,
      );
  final LibraryRepository repository;
  ThemeMode themeMode;
  ThemeAccent themeAccent;

  void setThemeAccent(ThemeAccent value) {
    if (value == themeAccent) return;
    repository.setSetting('themeAccent', value.name);
    themeAccent = value;
    notifyListeners();
  }

  void setTheme(ThemeMode value) {
    themeMode = value;
    repository.setSetting('themeMode', value.name);
    notifyListeners();
  }
}
