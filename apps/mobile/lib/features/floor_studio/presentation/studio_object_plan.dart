import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../domain/floor_studio.dart';

/// Top-down plan of the room: the walls, the round tables, and the custom objects. Objects
/// are selected by tapping and moved by dragging them, which snaps to half feet and stays
/// inside the room. Dragging starts only on an object, so a pan over empty floor still
/// scrolls the page.
class StudioObjectPlan extends StatefulWidget {
  const StudioObjectPlan({
    super.key,
    required this.widthFeet,
    required this.depthFeet,
    required this.tables,
    required this.tableDiameterFeet,
    required this.objects,
    required this.selectedId,
    required this.onSelect,
    required this.onMove,
    this.onMoveEnd,
  });

  final double widthFeet;
  final double depthFeet;
  final List<StudioTable> tables;
  final double tableDiameterFeet;
  final List<StudioObject> objects;
  final String? selectedId;
  final ValueChanged<String?> onSelect;
  final ValueChanged<StudioObject> onMove;

  /// Called once when a drag that moved an object ends.
  final VoidCallback? onMoveEnd;

  static const maxHeight = 360.0;

  /// Neither side of the plan is drawn smaller than this, so a long, thin room stays
  /// tappable. The plan then scrolls instead of shrinking.
  static const minSide = 48.0;

  @override
  State<StudioObjectPlan> createState() => _StudioObjectPlanState();
}

class _StudioObjectPlanState extends State<StudioObjectPlan> {
  final _canvasKey = GlobalKey();
  StudioObject? _dragging;
  Offset _dragStartFeet = Offset.zero;
  Offset _objectStartFeet = Offset.zero;

  RenderBox? get _box =>
      _canvasKey.currentContext?.findRenderObject() as RenderBox?;

  /// Converts a global pointer position to feet from the room's near-left corner.
  Offset? _feetAt(Offset globalPosition) {
    final box = _box;
    if (box == null || !box.hasSize || box.size.width <= 0) return null;
    final local = box.globalToLocal(globalPosition);
    final scale = box.size.width / widget.widthFeet;
    return Offset(local.dx / scale, local.dy / scale);
  }

  StudioObject? _objectAt(Offset globalPosition) {
    final feet = _feetAt(globalPosition);
    if (feet == null) return null;
    return studioObjectAt(widget.objects, feet.dx, feet.dy);
  }

  void _startDrag(Offset globalPosition) {
    final object = _objectAt(globalPosition);
    if (object == null) return;
    _dragging = object;
    _dragStartFeet = _feetAt(globalPosition)!;
    _objectStartFeet = Offset(object.x, object.y);
    widget.onSelect(object.id);
  }

  void _updateDrag(Offset globalPosition) {
    final object = _dragging;
    final feet = _feetAt(globalPosition);
    if (object == null || feet == null) return;
    final delta = feet - _dragStartFeet;
    final moved = object.copyWith(
      x: snapStudioFeet(_objectStartFeet.dx + delta.dx),
      y: snapStudioFeet(_objectStartFeet.dy + delta.dy),
    );
    widget.onMove(
      clampStudioObject(
        moved,
        widthFeet: widget.widthFeet,
        depthFeet: widget.depthFeet,
      ),
    );
  }

  void _endDrag() {
    if (_dragging == null) return;
    _dragging = null;
    widget.onMoveEnd?.call();
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        // One scale for both axes. Fit the width, cap the height, then grow back to the
        // minimum side; a very long room ends up wider or taller than the space and scrolls.
        final aspect = widget.depthFeet / widget.widthFeet;
        var width = constraints.maxWidth;
        var height = width * aspect;
        if (height > StudioObjectPlan.maxHeight) {
          height = StudioObjectPlan.maxHeight;
          width = height / aspect;
        }
        if (height < StudioObjectPlan.minSide) {
          height = StudioObjectPlan.minSide;
          width = height / aspect;
        }
        if (width < StudioObjectPlan.minSide) {
          width = StudioObjectPlan.minSide;
          height = width * aspect;
        }
        final canvas = SizedBox(
          key: const ValueKey('studio-object-plan-canvas'),
          width: width,
          height: height,
          child: RawGestureDetector(
            gestures: <Type, GestureRecognizerFactory>{
              _ObjectPanRecognizer:
                  GestureRecognizerFactoryWithHandlers<_ObjectPanRecognizer>(
                () => _ObjectPanRecognizer(
                  canStart: (position) => _objectAt(position) != null,
                ),
                (recognizer) {
                  recognizer.onDown = (details) {
                    _startDrag(details.globalPosition);
                  };
                  recognizer.onUpdate = (details) {
                    _updateDrag(details.globalPosition);
                  };
                  recognizer.onEnd = (_) => _endDrag();
                  recognizer.onCancel = _endDrag;
                },
              ),
              TapGestureRecognizer:
                  GestureRecognizerFactoryWithHandlers<TapGestureRecognizer>(
                TapGestureRecognizer.new,
                (recognizer) {
                  // Tapping an object already selects it on pointer down, so a tap only
                  // needs to clear the selection when it lands on empty floor.
                  recognizer.onTapUp = (details) {
                    if (_objectAt(details.globalPosition) == null) {
                      widget.onSelect(null);
                    }
                  };
                },
              ),
            },
            child: CustomPaint(
              key: _canvasKey,
              size: Size(width, height),
              painter: _StudioPlanPainter(
                widthFeet: widget.widthFeet,
                depthFeet: widget.depthFeet,
                tables: widget.tables,
                tableDiameterFeet: widget.tableDiameterFeet,
                objects: widget.objects,
                selectedId: widget.selectedId,
                wallColor: Theme.of(context).colorScheme.outline,
                floorColor:
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                tableColor: Theme.of(context).colorScheme.surface,
                selectionColor: Theme.of(context).colorScheme.primary,
              ),
            ),
          ),
        );
        return width > constraints.maxWidth
            ? SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: canvas,
              )
            : Center(child: canvas);
      },
    );
  }
}

/// A pan that only enters the gesture arena when the pointer starts on an object. It claims
/// that press straight away: otherwise the enclosing list's scroll wins a sideways drag and
/// the object never moves.
class _ObjectPanRecognizer extends PanGestureRecognizer {
  _ObjectPanRecognizer({required this.canStart});

  final bool Function(Offset globalPosition) canStart;

  @override
  bool isPointerAllowed(PointerEvent event) =>
      super.isPointerAllowed(event) && canStart(event.position);

  @override
  void addAllowedPointer(PointerDownEvent event) {
    super.addAllowedPointer(event);
    resolve(GestureDisposition.accepted);
  }
}

Color _fillFor(StudioObjectKind kind) => switch (kind) {
      StudioObjectKind.stage => const Color(0xFF455A64),
      StudioObjectKind.bar => const Color(0xFF8D6E63),
      StudioObjectKind.danceFloor => const Color(0xFFCE93D8),
      StudioObjectKind.djBooth => const Color(0xFF5C6BC0),
      StudioObjectKind.podium => const Color(0xFFA1887F),
      StudioObjectKind.buffet => const Color(0xFFD7CCC8),
      StudioObjectKind.backdrop => const Color(0xFF90A4AE),
      StudioObjectKind.planter => const Color(0xFF81C784),
      StudioObjectKind.placeholder => const Color(0xFFB0BEC5),
    };

class _StudioPlanPainter extends CustomPainter {
  _StudioPlanPainter({
    required this.widthFeet,
    required this.depthFeet,
    required this.tables,
    required this.tableDiameterFeet,
    required this.objects,
    required this.selectedId,
    required this.wallColor,
    required this.floorColor,
    required this.tableColor,
    required this.selectionColor,
  });

  final double widthFeet;
  final double depthFeet;
  final List<StudioTable> tables;
  final double tableDiameterFeet;
  final List<StudioObject> objects;
  final String? selectedId;
  final Color wallColor;
  final Color floorColor;
  final Color tableColor;
  final Color selectionColor;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / widthFeet;
    Offset toPx(double x, double y) => Offset(x * scale, y * scale);

    final room = Rect.fromLTWH(0, 0, size.width, size.height);
    canvas.drawRect(room, Paint()..color = floorColor);
    canvas.drawRect(
      room,
      Paint()
        ..color = wallColor
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );

    final tableFill = Paint()..color = tableColor;
    final tableStroke = Paint()
      ..color = wallColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final table in tables) {
      final centre = toPx(table.x, table.y);
      final radius = tableDiameterFeet / 2 * scale;
      canvas.drawCircle(centre, radius, tableFill);
      canvas.drawCircle(centre, radius, tableStroke);
    }

    for (final object in objects) {
      _paintObject(canvas, object, scale, toPx(object.x, object.y));
    }
  }

  void _paintObject(
    Canvas canvas,
    StudioObject object,
    double scale,
    Offset centre,
  ) {
    // Same rotation as the 3D scene: local x runs along the width, rotated about the
    // vertical axis, which is a plan rotation of -degrees on a y-down canvas.
    final radians = object.rotationDegrees * math.pi / 180;
    final cos = math.cos(radians);
    final sin = math.sin(radians);
    final halfW = object.widthFeet / 2 * scale;
    final halfD = object.depthFeet / 2 * scale;
    Offset corner(double lx, double lz) => Offset(
          centre.dx + (lx * cos + lz * sin),
          centre.dy + (-lx * sin + lz * cos),
        );
    final path = Path()
      ..addPolygon(
        [
          corner(-halfW, -halfD),
          corner(halfW, -halfD),
          corner(halfW, halfD),
          corner(-halfW, halfD),
        ],
        true,
      );

    final fill = _fillFor(object.kind);
    canvas.drawPath(path, Paint()..color = fill.withValues(alpha: 0.85));

    final selected = object.id == selectedId;
    canvas.drawPath(
      path,
      Paint()
        ..color = selected ? selectionColor : const Color(0xFF37474F)
        ..style = PaintingStyle.stroke
        ..strokeWidth = selected ? 3 : 1,
    );

    // Label: horizontal, clipped to the footprint so a long description never spills out.
    final onFill = ThemeData.estimateBrightnessForColor(fill) == Brightness.dark
        ? Colors.white
        : Colors.black87;
    final painter = TextPainter(
      text: TextSpan(
        text:
            object.description.isEmpty ? object.kind.label : object.description,
        style: TextStyle(
          color: onFill,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
      maxLines: 1,
      ellipsis: '…',
    )..layout(maxWidth: math.max(0, halfW * 2 - 4));
    canvas.save();
    canvas.clipPath(path);
    painter.paint(
      canvas,
      centre - Offset(painter.width / 2, painter.height / 2),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _StudioPlanPainter oldDelegate) => true;
}
