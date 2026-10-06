import 'package:flutter/material.dart';

import 'app_colors.dart';
import 'ops_colors.dart';

/// Venue Wrangler's operations design system: a charcoal command-centre workspace with warm
/// ivory surfaces, a coral primary, a cobalt selection/edit accent, and semantic status tones
/// (see [OpsColors]). Feature screens must read colours and text styles from
/// `Theme.of(context)` / `context.ops` rather than hardcoding values.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);

  static ThemeData dark() => _build(Brightness.dark);

  static const _radius = 14.0;
  static const _fieldRadius = 12.0;
  static const _touchHeight = 48.0;

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final ops = isDark ? OpsColors.dark : OpsColors.light;

    final scheme = isDark ? _darkScheme : _lightScheme;
    final textTheme = _textTheme(scheme);

    final border = BorderSide(color: ops.panelBorder);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_radius),
      side: border,
    );

    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: scheme.surface,
      canvasColor: scheme.surface,
      textTheme: textTheme,
      extensions: [ops],
      dividerTheme:
          DividerThemeData(color: ops.panelBorder, thickness: 1, space: 1),
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        foregroundColor: scheme.onSurface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: false,
        titleTextStyle:
            textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700),
        shape: Border(bottom: border),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: shape,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        minVerticalPadding: 8,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerHigh,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: border,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: border,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide(color: scheme.secondary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, _touchHeight),
          shape: const StadiumBorder(),
          textStyle:
              textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(64, _touchHeight),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shape: const StadiumBorder(),
          textStyle:
              textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, _touchHeight),
          foregroundColor: scheme.onSurface,
          side: border,
          shape: const StadiumBorder(),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, _touchHeight),
          foregroundColor: ops.primaryStrong,
          textStyle:
              textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
        ),
      ),
      iconButtonTheme: IconButtonThemeData(
        style: IconButton.styleFrom(
          minimumSize: const Size(_touchHeight, _touchHeight),
        ),
      ),
      floatingActionButtonTheme: FloatingActionButtonThemeData(
        backgroundColor: scheme.primary,
        foregroundColor: scheme.onPrimary,
        elevation: 2,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: scheme.surfaceContainerHigh,
        selectedColor: ops.info.bg,
        side: border,
        labelStyle: textTheme.labelMedium,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: ops.panelBorder,
        labelStyle: textTheme.labelLarge?.copyWith(fontWeight: FontWeight.w700),
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          side: border,
          selectedBackgroundColor: ops.info.bg,
          selectedForegroundColor: ops.info.fg,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.onPrimary
              : scheme.outline,
        ),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? scheme.primary
              : scheme.surfaceContainerHighest,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: shape,
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: RoundedRectangleBorder(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(20)),
          side: border,
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? AppColors.charcoalPanel : AppColors.charcoal,
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: AppColors.inkOnDark),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(_fieldRadius),
        ),
      ),
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        indicatorColor: ops.info.bg,
        height: 68,
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? AppColors.ivory : AppColors.charcoal,
          borderRadius: BorderRadius.circular(8),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: isDark ? AppColors.inkOnLight : AppColors.inkOnDark,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }

  static final ColorScheme _darkScheme = const ColorScheme.dark().copyWith(
    primary: AppColors.coral,
    onPrimary: AppColors.charcoal,
    primaryContainer: const Color(0xFF4A2326),
    onPrimaryContainer: const Color(0xFFFFD9DA),
    secondary: AppColors.cobalt,
    onSecondary: AppColors.charcoal,
    secondaryContainer: const Color(0xFF1F3470),
    onSecondaryContainer: const Color(0xFFD8E2FF),
    tertiary: AppColors.purpleOnDark,
    onTertiary: AppColors.charcoal,
    error: AppColors.redOnDark,
    onError: AppColors.charcoal,
    surface: AppColors.charcoal,
    onSurface: AppColors.inkOnDark,
    onSurfaceVariant: AppColors.mutedOnDark,
    surfaceContainerLowest: const Color(0xFF10151C),
    surfaceContainerLow: AppColors.charcoalRaised,
    surfaceContainer: const Color(0xFF1E2735),
    surfaceContainerHigh: AppColors.charcoalPanel,
    surfaceContainerHighest: const Color(0xFF2A3547),
    outline: const Color(0xFF6B7889),
    outlineVariant: AppColors.charcoalLine,
  );

  static final ColorScheme _lightScheme = const ColorScheme.light().copyWith(
    primary: AppColors.coral,
    onPrimary: AppColors.charcoal,
    primaryContainer: const Color(0xFFFFDAD9),
    onPrimaryContainer: const Color(0xFF5C1115),
    secondary: AppColors.cobaltStrongOnLight,
    onSecondary: AppColors.white,
    secondaryContainer: const Color(0xFFDCE4FF),
    onSecondaryContainer: const Color(0xFF0B2468),
    tertiary: AppColors.purpleOnLight,
    onTertiary: AppColors.white,
    error: AppColors.redOnLight,
    onError: AppColors.white,
    surface: AppColors.ivory,
    onSurface: AppColors.inkOnLight,
    onSurfaceVariant: AppColors.mutedOnLight,
    surfaceContainerLowest: AppColors.white,
    surfaceContainerLow: AppColors.white,
    surfaceContainer: const Color(0xFFFAF7F1),
    surfaceContainerHigh: AppColors.ivoryDeep,
    surfaceContainerHighest: const Color(0xFFE0D9CB),
    outline: const Color(0xFF7C8696),
    outlineVariant: AppColors.ivoryLine,
  );

  /// Compact operational type scale. Every style uses tabular figures so times, capacities,
  /// counts and schedules line up in columns.
  static TextTheme _textTheme(ColorScheme scheme) {
    const tabular = [FontFeature.tabularFigures()];
    TextStyle s(
      double size,
      FontWeight weight, {
      double height = 1.3,
      double letter = 0,
    }) =>
        TextStyle(
          fontSize: size,
          fontWeight: weight,
          height: height,
          letterSpacing: letter,
          color: scheme.onSurface,
          fontFeatures: tabular,
        );
    return TextTheme(
      displayLarge: s(40, FontWeight.w700, height: 1.15, letter: -0.5),
      displayMedium: s(32, FontWeight.w700, height: 1.15, letter: -0.4),
      displaySmall: s(26, FontWeight.w700, height: 1.2, letter: -0.3),
      headlineLarge: s(24, FontWeight.w700, height: 1.2, letter: -0.2),
      headlineMedium: s(22, FontWeight.w700, height: 1.25),
      headlineSmall: s(20, FontWeight.w700, height: 1.25),
      titleLarge: s(18, FontWeight.w700, height: 1.25),
      titleMedium: s(15, FontWeight.w600),
      titleSmall: s(13, FontWeight.w600),
      bodyLarge: s(15, FontWeight.w400, height: 1.4),
      bodyMedium: s(14, FontWeight.w400, height: 1.4),
      bodySmall: s(12, FontWeight.w400, height: 1.35)
          .copyWith(color: scheme.onSurfaceVariant),
      labelLarge: s(14, FontWeight.w600, letter: 0.1),
      labelMedium: s(12, FontWeight.w600, letter: 0.2),
      labelSmall: s(11, FontWeight.w600, letter: 0.3)
          .copyWith(color: scheme.onSurfaceVariant),
    );
  }
}
