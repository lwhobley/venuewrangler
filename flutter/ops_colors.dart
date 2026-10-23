import 'package:flutter/material.dart';

import 'app_colors.dart';

/// Operational status tones. Every status shown in the UI must pair its tone with text or an
/// icon (see StatusChip): colour alone is never the only signal.
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

class ToneColors {
  const ToneColors({required this.fg, required this.bg});

  final Color fg;
  final Color bg;
}

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

  /// Terracotta that meets text contrast on the current surface (accent700 on cream).
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
    success: ToneColors(fg: AppColors.greenOnDark, bg: Color(0x2E8FA073)),
    warning: ToneColors(fg: AppColors.amberOnDark, bg: Color(0x2EF6A06B)),
    vip: ToneColors(fg: AppColors.purpleOnDark, bg: Color(0x4756633F)),
    danger: ToneColors(fg: AppColors.redOnDark, bg: Color(0x2EF08A6B)),
    info: ToneColors(fg: AppColors.neutral200, bg: Color(0x2EC0B6A5)),
    neutral: ToneColors(fg: AppColors.mutedOnDark, bg: Color(0x1FC0B6A5)),
    primaryStrong: AppColors.accent300,
    gridLine: Color(0x14F9F4ED),
    panelBorder: AppColors.charcoalLine,
  );

  static const OpsColors light = OpsColors(
    success: ToneColors(fg: AppColors.greenOnLight, bg: Color(0x33728157)),
    warning: ToneColors(fg: AppColors.amberOnLight, bg: Color(0x33C67139)),
    vip: ToneColors(fg: AppColors.purpleOnLight, bg: Color(0x3356633F)),
    danger: ToneColors(fg: AppColors.redOnLight, bg: Color(0x299A3A22)),
    info: ToneColors(fg: AppColors.neutral800, bg: Color(0x33645C50)),
    neutral: ToneColors(fg: AppColors.mutedOnLight, bg: Color(0x1F645C50)),
    primaryStrong: AppColors.accent700,
    gridLine: Color(0x14201E1D),
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
  OpsColors get ops => Theme.of(this).extension<OpsColors>() ?? OpsColors.dark;
}
