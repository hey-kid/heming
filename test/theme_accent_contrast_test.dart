import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:heming/app/theme.dart';
import 'package:heming/app/theme_accent.dart';

double contrast(Color foreground, Color background) {
  final first = foreground.computeLuminance();
  final second = background.computeLuminance();
  return (math.max(first, second) + 0.05) / (math.min(first, second) + 0.05);
}

void main() {
  for (final accent in ThemeAccent.values) {
    for (final brightness in Brightness.values) {
      test('${accent.name} ${brightness.name} keeps text readable', () {
        for (final mobile in [false, true]) {
          final theme = hemingTheme(brightness, mobile: mobile, accent: accent);
          final colors = theme.colorScheme;
          final pairs = <String, (Color, Color)>{
            'button': (colors.onPrimary, colors.primary),
            'selected container': (
              colors.onPrimaryContainer,
              colors.primaryContainer,
            ),
            'selected label': (colors.primary, colors.primaryContainer),
            'tonal button': (
              colors.onSecondaryContainer,
              colors.secondaryContainer,
            ),
            'tertiary container': (
              colors.onTertiaryContainer,
              colors.tertiaryContainer,
            ),
            'body': (colors.onSurface, colors.surface),
            'secondary text': (
              colors.onSurfaceVariant,
              colors.surfaceContainerLow,
            ),
            'navigation accent': (
              colors.primary,
              colors.surfaceContainerLowest,
            ),
            'accent on page': (colors.primary, colors.surface),
            'snackbar': (
              theme.snackBarTheme.contentTextStyle!.color!,
              theme.snackBarTheme.backgroundColor!,
            ),
            'error': (colors.onError, colors.error),
          };
          for (final entry in pairs.entries) {
            expect(
              contrast(entry.value.$1, entry.value.$2),
              greaterThanOrEqualTo(4.5),
              reason: '${entry.key}, mobile=$mobile',
            );
          }
        }
      });
    }
  }

  test('default accent retains the established green in both modes', () {
    expect(
      hemingTheme(Brightness.light).colorScheme.primary,
      const Color(0xff25664c),
    );
    expect(
      hemingTheme(Brightness.dark).colorScheme.primary,
      const Color(0xff9bd5b5),
    );
  });
}
