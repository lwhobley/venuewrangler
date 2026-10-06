import 'dart:math' as math;

import 'floor_table.dart';

const kTableShapes = ['round', 'square', 'rect', 'booth'];

/// Editable layout geometry + labelling of one table. Operational state (status, party size,
/// holds) stays on [FloorTable] and is never touched by the layout editor.
class EditorTable {
  const EditorTable({
    required this.id,
    required this.label,
    required this.shape,
    required this.capacity,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
    this.rotation = 0,
    this.section = 'main',
    this.status = 'available',
  });

  factory EditorTable.fromFloorTable(FloorTable t) => EditorTable(
        id: t.id,
        label: t.label,
        shape: t.shape,
        capacity: t.capacity,
        x: t.x,
        y: t.y,
        width: t.width,
        height: t.height,
        rotation: t.rotation,
        section: t.section,
        status: t.status,
      );

  factory EditorTable.fromJson(Map<String, dynamic> json) => EditorTable(
        id: json['id'] as String,
        label: json['label'] as String,
        shape: json['shape'] as String,
        capacity: (json['capacity'] as num).toInt(),
        x: (json['x'] as num).toDouble(),
        y: (json['y'] as num).toDouble(),
        width: (json['width'] as num).toDouble(),
        height: (json['height'] as num).toDouble(),
        rotation: (json['rotation'] as num?)?.toDouble() ?? 0,
        section: json['section'] as String? ?? 'main',
        status: json['status'] as String? ?? 'available',
      );

  /// Local-only id until the table is published and the database assigns a real one.
  static const newPrefix = 'new-';

  final String id;
  final String label;
  final String shape;
  final int capacity;
  final double x;
  final double y;
  final double width;
  final double height;
  final double rotation;
  final String section;
  final String status;

  bool get isNew => id.startsWith(newPrefix);

  EditorTable copyWith({
    String? label,
    String? shape,
    int? capacity,
    double? x,
    double? y,
    double? width,
    double? height,
    double? rotation,
    String? section,
  }) =>
      EditorTable(
        id: id,
        label: label ?? this.label,
        shape: shape ?? this.shape,
        capacity: capacity ?? this.capacity,
        x: x ?? this.x,
        y: y ?? this.y,
        width: width ?? this.width,
        height: height ?? this.height,
        rotation: rotation ?? this.rotation,
        section: section ?? this.section,
        status: status,
      );

  /// Geometry/label columns only — safe to send on update without disturbing live status.
  Map<String, dynamic> toLayoutColumns() => {
        'label': label,
        'shape': shape,
        'capacity': capacity,
        'x': x,
        'y': y,
        'width': width,
        'height': height,
        'rotation': rotation,
        'section': section,
      };

  Map<String, dynamic> toJson() =>
      {'id': id, ...toLayoutColumns(), 'status': status};

  bool sameLayoutAs(EditorTable o) =>
      label == o.label &&
      shape == o.shape &&
      capacity == o.capacity &&
      x == o.x &&
      y == o.y &&
      width == o.width &&
      height == o.height &&
      rotation == o.rotation &&
      section == o.section;

  /// Axis-aligned bounds after rotation, for overlap and clamping checks.
  ({double left, double top, double right, double bottom}) get bounds {
    final r = rotation * math.pi / 180;
    final cx = x + width / 2;
    final cy = y + height / 2;
    final hw = (width * math.cos(r).abs() + height * math.sin(r).abs()) / 2;
    final hh = (width * math.sin(r).abs() + height * math.cos(r).abs()) / 2;
    return (left: cx - hw, top: cy - hh, right: cx + hw, bottom: cy + hh);
  }

  bool overlaps(EditorTable o) {
    final a = bounds;
    final b = o.bounds;
    return a.left < b.right &&
        a.right > b.left &&
        a.top < b.bottom &&
        a.bottom > b.top;
  }
}
