import 'package:flutter/material.dart';

import '../theme/ops_colors.dart';

/// A status pill that always carries text and an icon alongside its colour — never colour
/// alone — so status is readable without relying on hue (accessibility requirement).
class StatusChip extends StatelessWidget {
  const StatusChip({
    super.key,
    required this.label,
    required this.tone,
    this.icon,
    this.dense = false,
  });

  final String label;
  final Tone tone;

  /// Defaults to a glyph matching [tone] so the status is distinguishable without colour.
  final IconData? icon;
  final bool dense;

  static IconData defaultIcon(Tone tone) => switch (tone) {
        Tone.success => Icons.check_circle_outline,
        Tone.warning => Icons.schedule,
        Tone.vip => Icons.star_outline,
        Tone.danger => Icons.error_outline,
        Tone.info => Icons.radio_button_checked,
        Tone.neutral => Icons.remove_circle_outline,
      };

  @override
  Widget build(BuildContext context) {
    final colors = context.ops.of(tone);
    final textStyle =
        Theme.of(context).textTheme.labelMedium?.copyWith(color: colors.fg);
    return Semantics(
      label: label,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: dense ? 8 : 10,
          vertical: dense ? 3 : 5,
        ),
        decoration: BoxDecoration(
          color: colors.bg,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: colors.fg.withValues(alpha: 0.35)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon ?? defaultIcon(tone),
              size: dense ? 12 : 14,
              color: colors.fg,
            ),
            const SizedBox(width: 5),
            Text(label, style: textStyle),
          ],
        ),
      ),
    );
  }
}
