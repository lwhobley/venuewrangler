import 'package:flutter/material.dart';

import '../../../core/theme/ops_colors.dart';

/// How a table's operational status is presented: a semantic tone plus an icon and label, so
/// status is never conveyed by colour alone. Shared by the floor plan tiles, action sheet and
/// (later) the live legend.
class TableStatusStyle {
  const TableStatusStyle({
    required this.tone,
    required this.icon,
    required this.label,
  });

  final Tone tone;
  final IconData icon;
  final String label;

  static const _known = <String, TableStatusStyle>{
    'available': TableStatusStyle(
      tone: Tone.success,
      icon: Icons.check_circle_outline,
      label: 'Available',
    ),
    'seated': TableStatusStyle(
      tone: Tone.info,
      icon: Icons.event_seat_outlined,
      label: 'Seated',
    ),
    'dirty': TableStatusStyle(
      tone: Tone.warning,
      icon: Icons.cleaning_services_outlined,
      label: 'Needs reset',
    ),
    'reserved': TableStatusStyle(
      tone: Tone.vip,
      icon: Icons.bookmark_border,
      label: 'Reserved',
    ),
    'held': TableStatusStyle(
      tone: Tone.warning,
      icon: Icons.lock_clock_outlined,
      label: 'Held',
    ),
    'out_of_service': TableStatusStyle(
      tone: Tone.danger,
      icon: Icons.block,
      label: 'Out of service',
    ),
  };

  static TableStatusStyle of(String status) =>
      _known[status] ??
      TableStatusStyle(
        tone: Tone.neutral,
        icon: Icons.help_outline,
        label: status,
      );

  /// Statuses in the order the legend lists them.
  static List<MapEntry<String, TableStatusStyle>> get all =>
      _known.entries.toList();
}
