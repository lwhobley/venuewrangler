import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Operational status tones. Every status shown in the UI must pair its tone with text or an
/// icon (see StatusChip) — colour alone is never the only signal.
enum Tone {
  /// Ready, completed, available.
  success,

  /// Attention, delay, reset, warning.
  warning,

  /// VIP, priority, private, elevated service.
  vip,

  /// Error, out of service, cancelled, destructive.
  danger,

  /// Selection, editing, informational.
  info,

  /// Inactive, unknown, no state.
  neutral,
}

/// A tone's text/icon colour and its tinted container colour on the current brightness.
class ToneColors {
  const ToneColors({required this.fg, required this.bg});

  final Color fg;
  final Color bg;
}

/// Semantic colours attached to the theme so screens never hardcode `Colors.green` etc.
@immutable
class OpsColors extends ThemeExtension<OpsColors> {
  const OpsColors({
    required this.success,
    required this.warning,
    required this.vip,
    required this.danger,
    required this.info,
    required this.neutral,
    required this.primaryStrong,
    required this.gridLine,
    required this.panelBorder,
  });

  final ToneColors success;
  final ToneColors warning;
  final ToneColors vip;
  final ToneColors danger;
  final ToneColors info;
  final ToneColors neutral;

  /// Coral that still meets text contrast on the current surface (plain coral fails on ivory).
  final Color primaryStrong;

  /// Blueprint-grid line colour.
  final Color gridLine;

  /// Thin border for panels and cards.
  final Color panelBorder;

  ToneColors of(Tone tone) => switch (tone) {
        Tone.success => success,
        Tone.warning => warning,
        Tone.vip => vip,
        Tone.danger => danger,
        Tone.info => info,
        Tone.neutral => neutral,
      };

  static const OpsColors dark = OpsColors(
    success: ToneColors(fg: AppColors.greenOnDark, bg: Color(0x265BD39A)),
    warning: ToneColors(fg: AppColors.amberOnDark, bg: Color(0x26F5BC4A)),
    vip: ToneColors(fg: AppColors.purpleOnDark, bg: Color(0x26B59BFF)),
    danger: ToneColors(fg: AppColors.redOnDark, bg: Color(0x26FF8585)),
    info: ToneColors(fg: AppColors.cobaltOnDark, bg: Color(0x264D7CFE)),
    neutral: ToneColors(fg: AppColors.mutedOnDark, bg: Color(0x1FA3AFBF)),
    primaryStrong: AppColors.tealLight,
    gridLine: Color(0x14FFFFFF),
    panelBorder: AppColors.charcoalLine,
  );

  static const OpsColors light = OpsColors(
    success: ToneColors(fg: AppColors.greenOnLight, bg: Color(0x24146A43)),
    warning: ToneColors(fg: AppColors.amberOnLight, bg: Color(0x24F5BC4A)),
    vip: ToneColors(fg: AppColors.purpleOnLight, bg: Color(0x1F6742C4)),
    danger: ToneColors(fg: AppColors.redOnLight, bg: Color(0x1FB3261E)),
    info: ToneColors(fg: AppColors.cobaltStrongOnLight, bg: Color(0x242450CC)),
    neutral: ToneColors(fg: AppColors.mutedOnLight, bg: Color(0x1F566173)),
    primaryStrong: AppColors.teal,
    gridLine: Color(0x14141A22),
    panelBorder: AppColors.ivoryLine,
  );

  @override
  OpsColors copyWith({
    ToneColors? success,
    ToneColors? warning,
    ToneColors? vip,
    ToneColors? danger,
    ToneColors? info,
    ToneColors? neutral,
    Color? primaryStrong,
    Color? gridLine,
    Color? panelBorder,
  }) =>
      OpsColors(
        success: success ?? this.success,
        warning: warning ?? this.warning,
        vip: vip ?? this.vip,
        danger: danger ?? this.danger,
        info: info ?? this.info,
        neutral: neutral ?? this.neutral,
        primaryStrong: primaryStrong ?? this.primaryStrong,
        gridLine: gridLine ?? this.gridLine,
        panelBorder: panelBorder ?? this.panelBorder,
      );

  @override
  OpsColors lerp(ThemeExtension<OpsColors>? other, double t) {
    if (other is! OpsColors) return this;
    ToneColors l(ToneColors a, ToneColors b) => ToneColors(
          fg: Color.lerp(a.fg, b.fg, t)!,
          bg: Color.lerp(a.bg, b.bg, t)!,
        );
    return OpsColors(
      success: l(success, other.success),
      warning: l(warning, other.warning),
      vip: l(vip, other.vip),
      danger: l(danger, other.danger),
      info: l(info, other.info),
      neutral: l(neutral, other.neutral),
      primaryStrong: Color.lerp(primaryStrong, other.primaryStrong, t)!,
      gridLine: Color.lerp(gridLine, other.gridLine, t)!,
      panelBorder: Color.lerp(panelBorder, other.panelBorder, t)!,
    );
  }
}

extension OpsColorsContext on BuildContext {
  /// Semantic operational colours for the current theme.
  OpsColors get ops => Theme.of(this).extension<OpsColors>() ?? OpsColors.dark;
}
