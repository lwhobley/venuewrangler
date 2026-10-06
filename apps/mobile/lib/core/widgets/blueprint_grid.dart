import 'package:flutter/material.dart';

import '../theme/ops_colors.dart';

/// Architectural blueprint grid used behind the floor plan and other spatial workspaces.
/// Minor lines every [cell], a heavier major line every [majorEvery] cells.
class BlueprintGrid extends StatelessWidget {
  const BlueprintGrid({
    super.key,
    this.cell = 24,
    this.majorEvery = 5,
    this.child,
  });

  final double cell;
  final int majorEvery;
  final Widget? child;

  @override
  Widget build(BuildContext context) {
    final line = context.ops.gridLine;
    return CustomPaint(
      painter:
          BlueprintGridPainter(line: line, cell: cell, majorEvery: majorEvery),
      child: child,
    );
  }
}

class BlueprintGridPainter extends CustomPainter {
  const BlueprintGridPainter({
    required this.line,
    required this.cell,
    required this.majorEvery,
  });

  final Color line;
  final double cell;
  final int majorEvery;

  @override
  void paint(Canvas canvas, Size size) {
    final minor = Paint()
      ..color = line
      ..strokeWidth = 1;
    final major = Paint()
      ..color = line.withValues(alpha: (line.a * 2).clamp(0, 1).toDouble())
      ..strokeWidth = 1;

    var i = 0;
    for (var x = 0.0; x <= size.width; x += cell, i++) {
      canvas.drawLine(
        Offset(x, 0),
        Offset(x, size.height),
        i % majorEvery == 0 ? major : minor,
      );
    }
    i = 0;
    for (var y = 0.0; y <= size.height; y += cell, i++) {
      canvas.drawLine(
        Offset(0, y),
        Offset(size.width, y),
        i % majorEvery == 0 ? major : minor,
      );
    }
  }

  @override
  bool shouldRepaint(BlueprintGridPainter old) =>
      old.line != line || old.cell != cell || old.majorEvery != majorEvery;
}
