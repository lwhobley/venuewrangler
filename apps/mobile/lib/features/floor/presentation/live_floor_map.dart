import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/blueprint_grid.dart';
import '../domain/floor_plan.dart';
import '../domain/floor_table.dart';
import '../domain/table_status_style.dart';

/// The published floor plan drawn to scale with live table status. Pinch to zoom, drag to
/// pan, tap a table for its actions. When [highlightSection] is set, that section's tables
/// stand out and the rest are dimmed.
class LiveFloorMap extends StatefulWidget {
  const LiveFloorMap({
    super.key,
    required this.plan,
    required this.tables,
    required this.onTableTap,
    this.highlightSection,
  });

  final FloorPlan plan;
  final List<FloorTable> tables;
  final ValueChanged<FloorTable> onTableTap;
  final String? highlightSection;

  @override
  State<LiveFloorMap> createState() => _LiveFloorMapState();
}

class _LiveFloorMapState extends State<LiveFloorMap> {
  final _tc = TransformationController();
  Size? _fittedTo;

  @override
  void dispose() {
    _tc.dispose();
    super.dispose();
  }

  void _fit(Size viewport) {
    if (_fittedTo == viewport || viewport.isEmpty) return;
    _fittedTo = viewport;
    final p = widget.plan;
    final scale =
        math.min(viewport.width / p.width, viewport.height / p.height) * 0.95;
    final dx = (viewport.width - p.width * scale) / 2;
    final dy = (viewport.height - p.height * scale) / 2;
    final fitted = Matrix4.translationValues(dx, dy, 0)
      ..scaleByDouble(scale, scale, 1, 1);
    // Called during layout; apply once the frame is done.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _tc.value = fitted;
    });
  }

  bool _inHighlight(FloorTable t) {
    final key = widget.highlightSection?.trim().toLowerCase();
    return key == null || t.section.trim().toLowerCase() == key;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final plan = widget.plan;
    return LayoutBuilder(
      builder: (context, constraints) {
        _fit(constraints.biggest);
        return ClipRect(
          child: InteractiveViewer(
            transformationController: _tc,
            constrained: false,
            minScale: 0.2,
            maxScale: 4,
            boundaryMargin: const EdgeInsets.all(300),
            child: Container(
              width: plan.width,
              height: plan.height,
              decoration: BoxDecoration(
                color: theme.colorScheme.surfaceContainerLow,
                border: Border.all(color: context.ops.panelBorder, width: 2),
              ),
              child: Stack(
                children: [
                  const Positioned.fill(child: BlueprintGrid(cell: 20)),
                  for (final t in widget.tables)
                    Positioned(
                      left: t.x,
                      top: t.y,
                      width: t.width,
                      height: t.height,
                      child: Transform.rotate(
                        angle: t.rotation * math.pi / 180,
                        child: AnimatedOpacity(
                          duration: const Duration(milliseconds: 200),
                          opacity: _inHighlight(t) ? 1 : 0.3,
                          child: _MapTable(
                            table: t,
                            emphasised: widget.highlightSection != null &&
                                _inHighlight(t),
                            onTap: () => widget.onTableTap(t),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

class _MapTable extends StatelessWidget {
  const _MapTable({
    required this.table,
    required this.emphasised,
    required this.onTap,
  });

  final FloorTable table;
  final bool emphasised;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final style = TableStatusStyle.of(table.status);
    final tone = context.ops.of(style.tone);
    final radius = switch (table.shape) {
      'round' => BorderRadius.circular(math.max(table.width, table.height)),
      'booth' => const BorderRadius.vertical(
          top: Radius.circular(28),
          bottom: Radius.circular(6),
        ),
      _ => BorderRadius.circular(10),
    };
    return Semantics(
      button: true,
      label: 'Table ${table.label}, ${style.label}, ${table.capacity} seats',
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            color: tone.bg,
            borderRadius: radius,
            border: Border.all(
              color:
                  emphasised ? Theme.of(context).colorScheme.primary : tone.fg,
              width: emphasised ? 3 : 1.5,
            ),
          ),
          alignment: Alignment.center,
          child: FittedBox(
            fit: BoxFit.scaleDown,
            child: Padding(
              padding: const EdgeInsets.all(6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    table.label,
                    style: TextStyle(
                      color: tone.fg,
                      fontWeight: FontWeight.w800,
                      fontSize: 16,
                    ),
                  ),
                  Icon(style.icon, size: 14, color: tone.fg),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
