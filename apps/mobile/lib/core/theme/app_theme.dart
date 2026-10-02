import 'package:flutter/material.dart';

/// Minimal Phase 1 Material 3 theme. Replace the seed color and typography here once a real
/// design system exists; every feature screen should read colors/text styles from `Theme.of
/// (context)` rather than hardcoding values, so a future re-theme is a one-file change.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _themeFrom(Brightness.light);

  static ThemeData dark() => _themeFrom(Brightness.dark);

  static ThemeData _themeFrom(Brightness brightness) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF1B4D3E),
      brightness: brightness,
    );
    return ThemeData(
      useMaterial3: true,
      colorScheme: colorScheme,
      scaffoldBackgroundColor: colorScheme.surface,
    );
  }
}
