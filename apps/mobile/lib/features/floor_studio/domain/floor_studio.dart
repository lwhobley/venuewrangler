import 'dart:math' as math;

const defaultTableDiameterFeet = 6.0;
const defaultSeatsPerTable = 10;
const tableClearanceFeet = 3.0;
const _feetToMeters = 0.3048;

/// A round table's center, in feet from the room's near-left corner.
class StudioTable {
  const StudioTable(this.x, this.y);

  final double x;
  final double y;

  factory StudioTable.fromJson(Map<String, dynamic> json) =>
      StudioTable((json['x'] as num).toDouble(), (json['y'] as num).toDouble());

  Map<String, dynamic> toJson() => {'x': x, 'y': y};
}

/// Measured dimensions and generated table layout for one floor plan. Absent until saved.
class FloorStudioLayout {
  const FloorStudioLayout({
    this.id,
    required this.venueId,
    required this.floorPlanId,
    required this.widthFeet,
    required this.depthFeet,
    required this.verified,
    this.tableDiameterFeet = defaultTableDiameterFeet,
    this.seatsPerTable = defaultSeatsPerTable,
    this.tables = const [],
  });

  final String? id;
  final String venueId;
  final String floorPlanId;
  final double widthFeet;
  final double depthFeet;
  final bool verified;
  final double tableDiameterFeet;
  final int seatsPerTable;
  final List<StudioTable> tables;

  /// The most guests this layout can seat.
  int get capacity => tables.length * seatsPerTable;

  factory FloorStudioLayout.fromJson(Map<String, dynamic> json) =>
      FloorStudioLayout(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        floorPlanId: json['floor_plan_id'] as String,
        widthFeet: (json['width_feet'] as num).toDouble(),
        depthFeet: (json['depth_feet'] as num).toDouble(),
        verified: json['verified'] as bool,
        tableDiameterFeet: (json['table_diameter_feet'] as num).toDouble(),
        seatsPerTable: (json['seats_per_table'] as num).toInt(),
        tables: [
          for (final e in (json['layout'] as List? ?? const []))
            StudioTable.fromJson(e as Map<String, dynamic>),
        ],
      );

  /// Upsert payload. `id`, `organization_id`, `created_at` are set by the database.
  Map<String, dynamic> toUpsertJson() => {
        'venue_id': venueId,
        'floor_plan_id': floorPlanId,
        'width_feet': widthFeet,
        'depth_feet': depthFeet,
        'verified': verified,
        'table_diameter_feet': tableDiameterFeet,
        'seats_per_table': seatsPerTable,
        'layout': [for (final t in tables) t.toJson()],
      };
}

/// One candidate arrangement from [generateStudioLayouts].
class StudioLayoutOption {
  const StudioLayoutOption({required this.name, required this.tables});

  final String name;
  final List<StudioTable> tables;
}

/// Boundary and clearance problems with a layout. Empty means the layout is feasible.
List<String> validateStudioLayout({
  required double widthFeet,
  required double depthFeet,
  required double tableDiameterFeet,
  required List<StudioTable> tables,
}) {
  if (!widthFeet.isFinite ||
      !depthFeet.isFinite ||
      widthFeet <= 0 ||
      depthFeet <= 0) {
    return ['Room measurements must be finite and positive.'];
  }
  final issues = <String>[];
  final radius = tableDiameterFeet / 2 + tableClearanceFeet;
  for (var i = 0; i < tables.length; i++) {
    final table = tables[i];
    if (!table.x.isFinite || !table.y.isFinite) {
      issues.add('Table ${i + 1} has invalid coordinates.');
      continue;
    }
    if (table.x - radius < 0 ||
        table.y - radius < 0 ||
        table.x + radius > widthFeet ||
        table.y + radius > depthFeet) {
      issues
          .add('Table ${i + 1} extends beyond the room or required clearance.');
    }
    for (var j = 0; j < i; j++) {
      final other = tables[j];
      if (!other.x.isFinite || !other.y.isFinite) continue;
      final distance = math.sqrt(
        math.pow(table.x - other.x, 2) + math.pow(table.y - other.y, 2),
      );
      if (distance < radius * 2) {
        issues
            .add('Tables ${j + 1} and ${i + 1} overlap their clearance zones.');
      }
    }
  }
  return issues;
}

/// Generates up to three distinct, feasible round-table arrangements. Throws
/// [FormatException] when the room cannot seat the guest count at all.
List<StudioLayoutOption> generateStudioLayouts({
  required double widthFeet,
  required double depthFeet,
  required int guestCount,
  double tableDiameterFeet = defaultTableDiameterFeet,
  int seatsPerTable = defaultSeatsPerTable,
}) {
  if (!widthFeet.isFinite ||
      !depthFeet.isFinite ||
      widthFeet <= 0 ||
      depthFeet <= 0) {
    throw const FormatException('Enter finite, positive room measurements.');
  }
  if (guestCount <= 0) {
    throw const FormatException('Enter a positive guest count.');
  }
  final needed = (guestCount / seatsPerTable).ceil();
  final radius = tableDiameterFeet / 2 + tableClearanceFeet;
  final spacing = radius * 2 + 0.5;
  final maxColumns = ((widthFeet - radius * 2) / spacing).floor() + 1;
  final maxRows = ((depthFeet - radius * 2) / spacing).floor() + 1;
  if (maxColumns <= 0 || maxRows <= 0) {
    throw const FormatException(
      'The room is too small for a table with clearance.',
    );
  }

  final shapes = <({int columns, int rows, double aspect})>[];
  for (var columns = 1; columns <= math.min(maxColumns, needed); columns++) {
    final rows = (needed / columns).ceil();
    if (rows > maxRows) continue;
    final width = radius * 2 + (columns - 1) * spacing;
    final height = radius * 2 + (rows - 1) * spacing;
    shapes.add((columns: columns, rows: rows, aspect: width / height));
  }
  if (shapes.isEmpty) {
    throw const FormatException(
      'The confirmed guest count cannot fit in this room.',
    );
  }

  final roomAspect = widthFeet / depthFeet;
  final balanced = [...shapes]..sort(
      (a, b) => (math.log(a.aspect / roomAspect))
          .abs()
          .compareTo((math.log(b.aspect / roomAspect)).abs()),
    );
  final wide = [...shapes]..sort((a, b) => b.aspect.compareTo(a.aspect));
  final deep = [...shapes]..sort((a, b) => a.aspect.compareTo(b.aspect));

  final options = <StudioLayoutOption>[];
  final signatures = <String>{};
  for (final (strategy, candidates) in [balanced, wide, deep].indexed) {
    for (final shape in candidates) {
      final columns = (needed / shape.rows).ceil();
      final maxXSpacing =
          columns > 1 ? (widthFeet - radius * 2) / (columns - 1) : spacing;
      final maxYSpacing = shape.rows > 1
          ? (depthFeet - radius * 2) / (shape.rows - 1)
          : spacing;
      final xSpacing = strategy == 1 ? (spacing + maxXSpacing) / 2 : spacing;
      final ySpacing = strategy == 2 ? (spacing + maxYSpacing) / 2 : spacing;
      final tables = _centeredTables(
        widthFeet,
        depthFeet,
        needed,
        shape.rows,
        xSpacing,
        ySpacing,
      );
      if (validateStudioLayout(
        widthFeet: widthFeet,
        depthFeet: depthFeet,
        tableDiameterFeet: tableDiameterFeet,
        tables: tables,
      ).isNotEmpty) {
        continue;
      }
      final signature = tables
          .map((t) => '${t.x.toStringAsFixed(4)},${t.y.toStringAsFixed(4)}')
          .join(';');
      if (!signatures.add(signature)) continue;
      options.add(
        StudioLayoutOption(
          name: ['Balanced grid', 'Wide rows', 'Deep rows'][strategy],
          tables: tables,
        ),
      );
      break;
    }
  }
  if (options.isEmpty) {
    throw const FormatException(
      'Cannot produce a feasible layout for this room and guest count.',
    );
  }
  return options;
}

List<StudioTable> _centeredTables(
  double widthFeet,
  double depthFeet,
  int needed,
  int rows,
  double xSpacing,
  double ySpacing,
) {
  final perRow = List<int>.filled(rows, needed ~/ rows);
  var extra = needed % rows;
  for (var offset = 0; offset < rows ~/ 2 && extra >= 2; offset++) {
    final left = rows ~/ 2 - 1 - offset;
    final right = rows - 1 - left;
    perRow[left]++;
    perRow[right]++;
    extra -= 2;
  }
  if (extra == 1) perRow[(rows - 1) ~/ 2]++;

  return [
    for (var row = 0; row < rows; row++)
      for (var column = 0; column < perRow[row]; column++)
        StudioTable(
          widthFeet / 2 + (column - (perRow[row] - 1) / 2) * xSpacing,
          depthFeet / 2 + (row - (rows - 1) / 2) * ySpacing,
        ),
  ];
}

/// Scene data for the 3D preview, in meters. Guests fill tables in order, up to
/// [FloorStudioLayout.seatsPerTable] each, so occupancy matches the guest count
/// rather than an invented seating chart.
Map<String, Object?> buildStudioSceneData({
  required FloorStudioLayout layout,
  required int guestCount,
}) {
  var remaining = guestCount;
  final tableData = [
    for (final table in layout.tables)
      () {
        final occupiedSeats = remaining.clamp(0, layout.seatsPerTable);
        remaining = (remaining - occupiedSeats).clamp(0, 1 << 31);
        return {
          'x': table.x * _feetToMeters,
          'y': table.y * _feetToMeters,
          'occupiedSeats': occupiedSeats,
        };
      }(),
  ];
  return {
    'widthMeters': layout.widthFeet * _feetToMeters,
    'heightMeters': layout.depthFeet * _feetToMeters,
    'tableDiameterMeters': layout.tableDiameterFeet * _feetToMeters,
    'seatsPerTable': layout.seatsPerTable,
    'tables': tableData,
  };
}
