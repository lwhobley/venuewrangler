import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'app_colors.dart';
import 'ops_colors.dart';

/// Venue Wrangler on the Organic design system: cream and sand ground, terracotta primary,
/// sage second voice, Caprasimo display type over Figtree, pill controls and 28px containers.
/// Feature screens read colours and styles from `Theme.of(context)` / `context.ops`.
class AppTheme {
  const AppTheme._();

  static ThemeData light() => _build(Brightness.light);
  static ThemeData dark() => _build(Brightness.dark);

  static const _card = 28.0;
  static const _field = 999.0;
  static const _touchHeight = 48.0;

  static ThemeData _build(Brightness brightness) {
    final isDark = brightness == Brightness.dark;
    final ops = isDark ? OpsColors.dark : OpsColors.light;
    final scheme = isDark ? _darkScheme : _lightScheme;
    final textTheme = _textTheme(scheme);

    final border = BorderSide(color: ops.panelBorder);
    final cardShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(_card),
    );
    const pill = StadiumBorder();

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
        titleTextStyle: textTheme.headlineSmall,
        iconTheme: IconThemeData(color: scheme.onSurface),
        actionsIconTheme: IconThemeData(color: scheme.onSurface),
      ),
      cardTheme: CardThemeData(
        color: scheme.surfaceContainerLow,
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: cardShape,
      ),
      listTileTheme: ListTileThemeData(
        iconColor: scheme.onSurfaceVariant,
        minVerticalPadding: 8,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: scheme.surfaceContainerLow,
        contentPadding:
            const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_field),
          borderSide: border,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_field),
          borderSide: border,
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_field),
          borderSide: BorderSide(color: scheme.primary, width: 2),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_field),
          borderSide: BorderSide(color: scheme.error),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(_field),
          borderSide: BorderSide(color: scheme.error, width: 2),
        ),
        labelStyle: TextStyle(color: scheme.onSurfaceVariant),
      ),
      filledButtonTheme: FilledButtonThemeData(
        style: FilledButton.styleFrom(
          minimumSize: const Size(64, _touchHeight),
          shape: pill,
          textStyle: GoogleFonts.caprasimo(fontSize: 16),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          minimumSize: const Size(64, _touchHeight),
          backgroundColor: scheme.primary,
          foregroundColor: scheme.onPrimary,
          elevation: 0,
          shape: pill,
          textStyle: GoogleFonts.caprasimo(fontSize: 16),
        ),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(64, _touchHeight),
          foregroundColor: scheme.onSurface,
          side: border,
          shape: pill,
          textStyle:
              GoogleFonts.figtree(fontSize: 15, fontWeight: FontWeight.w600),
        ),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(
          minimumSize: const Size(48, _touchHeight),
          foregroundColor: ops.primaryStrong,
          shape: pill,
          textStyle:
              GoogleFonts.figtree(fontSize: 15, fontWeight: FontWeight.w700),
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
        shape: const CircleBorder(),
      ),
      chipTheme: ChipThemeData(
        backgroundColor: Colors.transparent,
        selectedColor: scheme.primary,
        secondarySelectedColor: scheme.primary,
        side: border,
        labelStyle: textTheme.labelLarge,
        secondaryLabelStyle:
            textTheme.labelLarge?.copyWith(color: scheme.onPrimary),
        checkmarkColor: scheme.onPrimary,
        shape: pill,
      ),
      tabBarTheme: TabBarThemeData(
        labelColor: scheme.onSurface,
        unselectedLabelColor: scheme.onSurfaceVariant,
        indicatorColor: scheme.primary,
        dividerColor: ops.panelBorder,
        labelStyle: textTheme.labelLarge,
      ),
      segmentedButtonTheme: SegmentedButtonThemeData(
        style: SegmentedButton.styleFrom(
          side: border,
          shape: pill,
          selectedBackgroundColor: scheme.primary,
          selectedForegroundColor: scheme.onPrimary,
        ),
      ),
      switchTheme: SwitchThemeData(
        thumbColor: WidgetStateProperty.all(
          isDark ? AppColors.neutral100 : AppColors.ivory,
        ),
        trackOutlineColor: WidgetStateProperty.all(Colors.transparent),
        trackColor: WidgetStateProperty.resolveWith(
          (s) => s.contains(WidgetState.selected)
              ? AppColors.sage700
              : AppColors.neutral400,
        ),
      ),
      dialogTheme: DialogThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(32)),
      ),
      bottomSheetTheme: BottomSheetThemeData(
        backgroundColor: scheme.surfaceContainerLow,
        showDragHandle: true,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
        ),
      ),
      snackBarTheme: SnackBarThemeData(
        behavior: SnackBarBehavior.floating,
        backgroundColor: isDark ? AppColors.neutral700 : AppColors.charcoal,
        contentTextStyle:
            textTheme.bodyMedium?.copyWith(color: AppColors.inkOnDark),
        shape: pill,
      ),
      // Floating dark pill dock, as in the mobile design: charcoal capsule, terracotta-tinted
      // selection, cream labels.
      navigationBarTheme: NavigationBarThemeData(
        backgroundColor: isDark ? const Color(0xFF1D1B19) : AppColors.charcoal,
        indicatorColor: AppColors.accent.withValues(alpha: 0.28),
        indicatorShape: pill,
        height: 68,
        labelBehavior: NavigationDestinationLabelBehavior.alwaysShow,
        iconTheme: WidgetStateProperty.resolveWith(
          (states) => IconThemeData(
            color: states.contains(WidgetState.selected)
                ? AppColors.accent300
                : AppColors.neutral400,
          ),
        ),
        labelTextStyle: WidgetStateProperty.resolveWith(
          (states) => GoogleFonts.figtree(
            fontSize: 11,
            fontWeight: FontWeight.w700,
            color: states.contains(WidgetState.selected)
                ? AppColors.accent300
                : AppColors.neutral400,
          ),
        ),
      ),
      pageTransitionsTheme: const PageTransitionsTheme(
        builders: {
          TargetPlatform.android: FadeForwardsPageTransitionsBuilder(),
          TargetPlatform.iOS: CupertinoPageTransitionsBuilder(),
        },
      ),
      tooltipTheme: TooltipThemeData(
        decoration: BoxDecoration(
          color: isDark ? AppColors.neutral100 : AppColors.charcoal,
          borderRadius: BorderRadius.circular(999),
        ),
        textStyle: textTheme.bodySmall?.copyWith(
          color: isDark ? AppColors.inkOnLight : AppColors.inkOnDark,
        ),
      ),
      progressIndicatorTheme: ProgressIndicatorThemeData(color: scheme.primary),
    );
  }

  static final ColorScheme _lightScheme = const ColorScheme.light().copyWith(
    primary: AppColors.accent,
    // Ink, not cream: cream on terracotta is 3.0:1, ink is 4.6:1 (WCAG AA needs 4.5:1).
    onPrimary: AppColors.inkOnLight,
    primaryContainer: AppColors.accent200,
    onPrimaryContainer: AppColors.accent800,
    secondary: AppColors.sage700,
    onSecondary: AppColors.ivory,
    secondaryContainer: AppColors.sage200,
    onSecondaryContainer: AppColors.sage900,
    tertiary: AppColors.sage700,
    onTertiary: AppColors.ivory,
    error: AppColors.redOnLight,
    onError: AppColors.ivory,
    surface: AppColors.ivory,
    onSurface: AppColors.inkOnLight,
    onSurfaceVariant: AppColors.mutedOnLight,
    surfaceContainerLowest: AppColors.ivory,
    surfaceContainerLow: AppColors.ivoryDeep,
    surfaceContainer: AppColors.ivoryDeep,
    // neutral200, not 300: muted text on neutral300 is 4.4:1.
    surfaceContainerHigh: AppColors.neutral200,
    surfaceContainerHighest: AppColors.neutral200,
    outline: AppColors.neutral600,
    outlineVariant: AppColors.ivoryLine,
  );

  static final ColorScheme _darkScheme = const ColorScheme.dark().copyWith(
    primary: AppColors.accent400,
    onPrimary: AppColors.neutral900,
    primaryContainer: AppColors.accent800,
    onPrimaryContainer: AppColors.accent200,
    secondary: AppColors.sage400,
    onSecondary: AppColors.neutral900,
    secondaryContainer: AppColors.sage800,
    onSecondaryContainer: AppColors.sage200,
    tertiary: AppColors.sage300,
    onTertiary: AppColors.neutral900,
    error: AppColors.redOnDark,
    onError: AppColors.neutral900,
    surface: AppColors.charcoal,
    onSurface: AppColors.inkOnDark,
    onSurfaceVariant: AppColors.mutedOnDark,
    surfaceContainerLowest: Color(0xFF1D1B19),
    // Cards use the raised shade and the top step uses the panel shade: muted text on the old
    // neutral700 step was 3.3:1.
    surfaceContainerLow: AppColors.charcoalRaised,
    surfaceContainer: AppColors.charcoalRaised,
    surfaceContainerHigh: AppColors.charcoalPanel,
    surfaceContainerHighest: AppColors.charcoalPanel,
    outline: AppColors.neutral500,
    outlineVariant: AppColors.charcoalLine,
  );

  /// Caprasimo for headings and metrics, Figtree for body and labels. Body styles keep tabular
  /// figures so times, capacities and counts line up in columns.
  static TextTheme _textTheme(ColorScheme scheme) {
    const tabular = [FontFeature.tabularFigures()];
    TextStyle head(double size, {double height = 1.12}) =>
        GoogleFonts.caprasimo(
          fontSize: size,
          height: height,
          letterSpacing: -0.015 * size,
          color: scheme.onSurface,
          fontFeatures: tabular,
        );
    TextStyle body(
      double size,
      FontWeight w, {
      double height = 1.4,
      double letter = 0,
    }) =>
        GoogleFonts.figtree(
          fontSize: size,
          fontWeight: w,
          height: height,
          letterSpacing: letter,
          color: scheme.onSurface,
          fontFeatures: tabular,
        );
    return TextTheme(
      displayLarge: head(42),
      displayMedium: head(34),
      displaySmall: head(28),
      headlineLarge: head(26),
      headlineMedium: head(22),
      headlineSmall: head(20),
      titleLarge: head(18),
      titleMedium: body(15, FontWeight.w700),
      titleSmall: body(13, FontWeight.w700),
      bodyLarge: body(15, FontWeight.w400),
      bodyMedium: body(14, FontWeight.w400),
      bodySmall: body(12, FontWeight.w400, height: 1.35)
          .copyWith(color: scheme.onSurfaceVariant),
      labelLarge: body(14, FontWeight.w600, height: 1.3, letter: 0.1),
      labelMedium: body(12, FontWeight.w600, height: 1.3, letter: 0.2),
      labelSmall: body(11, FontWeight.w700, height: 1.3, letter: 0.8)
          .copyWith(color: scheme.onSurfaceVariant),
    );
  }
}
