import 'package:flutter/material.dart';
import 'theme_accent.dart';

ThemeData hemingTheme(
  Brightness brightness, {
  bool mobile = false,
  ThemeAccent accent = ThemeAccent.forest,
}) {
  return mobile
      ? _mobileTheme(brightness, accent)
      : _desktopTheme(brightness, accent);
}

ThemeData _baseTheme(Brightness brightness, ThemeAccent accent) {
  final dark = brightness == Brightness.dark;
  final generated = ColorScheme.fromSeed(
    seedColor: accent.seed,
    brightness: brightness,
    dynamicSchemeVariant: accent == ThemeAccent.graphite
        ? DynamicSchemeVariant.neutral
        : DynamicSchemeVariant.tonalSpot,
  );
  // Keep the established green while deriving every other accent's tonal roles
  // from its seed. Light buttons use the curated swatch; dark buttons use a
  // lighter tone so they remain legible against the neutral dark surfaces.
  final forest = accent == ThemeAccent.forest;
  final scheme = generated.copyWith(
    primary: dark
        ? (forest ? const Color(0xff9bd5b5) : generated.primary)
        : accent.seed,
    onPrimary: dark
        ? (forest ? const Color(0xff103b2b) : generated.onPrimary)
        : Colors.white,
    primaryContainer: forest
        ? (dark ? const Color(0xff244b3b) : const Color(0xffe1f0e7))
        : (dark
              ? generated.primaryContainer
              : Color.alphaBlend(
                  accent.seed.withValues(alpha: 0.1),
                  Colors.white,
                )),
    onPrimaryContainer: forest
        ? (dark ? const Color(0xffc2ecd4) : const Color(0xff214e3b))
        : generated.onPrimaryContainer,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: scheme.surface,
    fontFamily: 'Microsoft YaHei',
    fontFamilyFallback: const ['Noto Sans CJK SC', 'sans-serif'],
    textTheme: const TextTheme(
      headlineMedium: TextStyle(
        fontSize: 26,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      titleLarge: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
      titleMedium: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      bodyMedium: TextStyle(fontSize: 14, height: 1.5),
      bodySmall: TextStyle(fontSize: 12, height: 1.5),
    ),
    dividerTheme: DividerThemeData(
      color: scheme.outlineVariant,
      thickness: 1,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(9)),
        side: BorderSide(color: scheme.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      border: OutlineInputBorder(borderRadius: BorderRadius.circular(9)),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      backgroundColor: scheme.primaryContainer,
      actionTextColor: scheme.onPrimaryContainer,
      contentTextStyle: TextStyle(color: scheme.onPrimaryContainer),
    ),
  );
}

ThemeData _mobileTheme(Brightness brightness, ThemeAccent accent) {
  final dark = brightness == Brightness.dark;
  final base = _baseTheme(brightness, accent);
  final colors = base.colorScheme.copyWith(
    surface: dark ? const Color(0xff111214) : const Color(0xfff2f3f5),
    surfaceContainerLowest: dark ? const Color(0xff1c1d20) : Colors.white,
    surfaceContainerLow: dark
        ? const Color(0xff25272a)
        : const Color(0xffeef0f2),
    onSurface: dark ? const Color(0xfff1f2f3) : const Color(0xff202124),
    onSurfaceVariant: dark ? const Color(0xffaaadb3) : const Color(0xff666a70),
    outlineVariant: dark ? const Color(0xff36393c) : const Color(0xffe3e5e8),
  );
  final typography = ThemeData(brightness: brightness).textTheme
      .copyWith(
        headlineMedium: const TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
          height: 1.3,
        ),
        titleLarge: const TextStyle(
          fontSize: 21,
          fontWeight: FontWeight.w600,
          letterSpacing: -0.3,
          height: 1.3,
        ),
        titleMedium: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w600,
          height: 1.35,
        ),
        bodyLarge: const TextStyle(fontSize: 16, height: 1.45),
        bodyMedium: const TextStyle(fontSize: 14, height: 1.4),
        bodySmall: const TextStyle(fontSize: 12, height: 1.4),
        labelLarge: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      )
      .apply(bodyColor: colors.onSurface, displayColor: colors.onSurface);
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(13));
  return base.copyWith(
    colorScheme: colors,
    scaffoldBackgroundColor: colors.surface,
    textTheme: typography,
    dividerTheme: DividerThemeData(
      color: colors.outlineVariant,
      thickness: 0.5,
      space: 1,
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 48),
        shape: shape,
        side: BorderSide(color: colors.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(44, 44),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(44, 44),
        padding: const EdgeInsets.all(10),
      ),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: colors.surfaceContainerLow,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: colors.primary, width: 1.2),
      ),
      hintStyle: TextStyle(color: colors.onSurfaceVariant, fontSize: 14),
      contentPadding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
    ),
    navigationBarTheme: NavigationBarThemeData(
      backgroundColor: colors.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      indicatorColor: Colors.transparent,
      elevation: 0,
      labelTextStyle: WidgetStateProperty.resolveWith(
        (states) => TextStyle(
          fontSize: 11,
          fontWeight: states.contains(WidgetState.selected)
              ? FontWeight.w600
              : FontWeight.w400,
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
      ),
      iconTheme: WidgetStateProperty.resolveWith(
        (states) => IconThemeData(
          size: 24,
          color: states.contains(WidgetState.selected)
              ? colors.primary
              : colors.onSurfaceVariant,
        ),
      ),
    ),
  );
}

ThemeData _desktopTheme(Brightness brightness, ThemeAccent accent) {
  final base = _mobileTheme(brightness, accent);
  final colors = base.colorScheme;
  final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(12));
  return base.copyWith(
    textTheme: base.textTheme
        .copyWith(
          titleLarge: const TextStyle(
            fontSize: 20,
            fontWeight: FontWeight.w600,
            height: 1.35,
          ),
          bodyLarge: const TextStyle(fontSize: 15, height: 1.45),
          bodySmall: TextStyle(
            fontSize: 12,
            height: 1.5,
            color: colors.onSurfaceVariant,
          ),
        )
        .apply(
          fontFamily: 'Microsoft YaHei',
          bodyColor: colors.onSurface,
          displayColor: colors.onSurface,
        ),
    filledButtonTheme: FilledButtonThemeData(
      style: FilledButton.styleFrom(
        minimumSize: const Size(0, 42),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: OutlinedButton.styleFrom(
        minimumSize: const Size(0, 42),
        shape: shape,
        side: BorderSide(color: colors.outlineVariant),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      ),
    ),
    textButtonTheme: TextButtonThemeData(
      style: TextButton.styleFrom(
        minimumSize: const Size(40, 40),
        shape: shape,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      ),
    ),
    iconButtonTheme: IconButtonThemeData(
      style: IconButton.styleFrom(
        minimumSize: const Size(40, 40),
        padding: const EdgeInsets.all(10),
        shape: shape,
      ),
    ),
    popupMenuTheme: PopupMenuThemeData(
      color: colors.surfaceContainerLowest,
      surfaceTintColor: Colors.transparent,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
    ),
    scrollbarTheme: ScrollbarThemeData(
      thickness: const WidgetStatePropertyAll(5),
      radius: const Radius.circular(6),
      thumbColor: WidgetStatePropertyAll(
        colors.onSurfaceVariant.withValues(alpha: 0.25),
      ),
    ),
  );
}
