import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/floor_studio/domain/floor_studio.dart';

FloorStudioLayout _layout({
  double width = 40,
  double depth = 40,
  List<StudioTable> tables = const [],
  int seatsPerTable = defaultSeatsPerTable,
}) =>
    FloorStudioLayout(
      venueId: 'venue',
      floorPlanId: 'plan',
      widthFeet: width,
      depthFeet: depth,
      verified: true,
      seatsPerTable: seatsPerTable,
      tables: tables,
    );

void main() {
  group('generateStudioLayouts', () {
    test('generates feasible arrangements that seat the guests', () {
      final options =
          generateStudioLayouts(widthFeet: 80, depthFeet: 60, guestCount: 120);
      expect(options, isNotEmpty);
      for (final option in options) {
        expect(
          option.tables.length * defaultSeatsPerTable,
          greaterThanOrEqualTo(120),
        );
        expect(
          validateStudioLayout(
            widthFeet: 80,
            depthFeet: 60,
            tableDiameterFeet: defaultTableDiameterFeet,
            tables: option.tables,
          ),
          isEmpty,
        );
      }
    });

    test('rejects a room too small for any table with clearance', () {
      expect(
        () => generateStudioLayouts(widthFeet: 5, depthFeet: 5, guestCount: 20),
        throwsFormatException,
      );
    });

    test('rejects non-positive room measurements', () {
      expect(
        () =>
            generateStudioLayouts(widthFeet: 0, depthFeet: 40, guestCount: 10),
        throwsFormatException,
      );
    });

    test('rejects a non-positive guest count', () {
      expect(
        () =>
            generateStudioLayouts(widthFeet: 80, depthFeet: 60, guestCount: 0),
        throwsFormatException,
      );
    });
  });

  group('validateStudioLayout', () {
    test('flags a table that extends past the room boundary', () {
      expect(
        validateStudioLayout(
          widthFeet: 20,
          depthFeet: 20,
          tableDiameterFeet: 6,
          tables: const [StudioTable(1, 1)],
        ),
        isNotEmpty,
      );
    });

    test('flags overlapping clearance zones', () {
      expect(
        validateStudioLayout(
          widthFeet: 40,
          depthFeet: 40,
          tableDiameterFeet: 6,
          tables: const [StudioTable(15, 15), StudioTable(16, 15)],
        ),
        isNotEmpty,
      );
    });

    test('accepts a single well-clear table', () {
      expect(
        validateStudioLayout(
          widthFeet: 40,
          depthFeet: 40,
          tableDiameterFeet: 6,
          tables: const [StudioTable(20, 20)],
        ),
        isEmpty,
      );
    });
  });

  group('FloorStudioLayout', () {
    test('capacity is tables times seats per table', () {
      final layout = _layout(
        seatsPerTable: 8,
        tables: const [StudioTable(5, 5), StudioTable(10, 5)],
      );
      expect(layout.capacity, 16);
    });

    test('capacity is zero before any layout is generated', () {
      expect(_layout().capacity, 0);
    });

    test('round-trips through JSON with snake_case keys', () {
      final layout = FloorStudioLayout(
        id: 'layout-1',
        venueId: 'venue',
        floorPlanId: 'plan',
        widthFeet: 80,
        depthFeet: 60,
        verified: true,
        tables: const [StudioTable(5, 5)],
      );
      final json = {
        'id': 'layout-1',
        'venue_id': 'venue',
        'floor_plan_id': 'plan',
        'width_feet': 80,
        'depth_feet': 60,
        'verified': true,
        'table_diameter_feet': defaultTableDiameterFeet,
        'seats_per_table': defaultSeatsPerTable,
        'layout': [
          {'x': 5, 'y': 5},
        ],
      };
      final parsed = FloorStudioLayout.fromJson(json);
      expect(parsed.floorPlanId, layout.floorPlanId);
      expect(parsed.tables.single.x, 5);
      expect(parsed.toUpsertJson()['floor_plan_id'], 'plan');
      expect(parsed.toUpsertJson()['layout'], [
        {'x': 5.0, 'y': 5.0},
      ]);
    });
  });

  group('buildStudioSceneData', () {
    final layout = _layout(
      width: 80,
      depth: 60,
      tables: const [StudioTable(5, 5), StudioTable(10, 5), StudioTable(15, 5)],
    );

    test('fills tables in order up to the guest count', () {
      final data = buildStudioSceneData(layout: layout, guestCount: 15);
      final tables = data['tables'] as List;
      expect((tables[0] as Map)['occupiedSeats'], defaultSeatsPerTable);
      expect((tables[1] as Map)['occupiedSeats'], 5);
      expect((tables[2] as Map)['occupiedSeats'], 0);
    });

    test('never exceeds seatsPerTable', () {
      final data = buildStudioSceneData(layout: layout, guestCount: 999);
      for (final entry in data['tables'] as List) {
        expect((entry as Map)['occupiedSeats'], defaultSeatsPerTable);
      }
    });

    test('converts feet to meters for the renderer', () {
      final data = buildStudioSceneData(layout: layout, guestCount: 0);
      expect(data['widthMeters'], closeTo(80 * 0.3048, 0.001));
      expect(data['heightMeters'], closeTo(60 * 0.3048, 0.001));
      expect(
        data['tableDiameterMeters'],
        closeTo(defaultTableDiameterFeet * 0.3048, 0.001),
      );
    });
  });
}
