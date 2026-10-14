import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/floor_studio/domain/floor_studio.dart';

Map<String, dynamic> _savedRow({List<Object?>? objects, bool withKey = true}) =>
    {
      'id': 'layout-1',
      'venue_id': 'venue',
      'floor_plan_id': 'plan',
      'width_feet': 60,
      'depth_feet': 40,
      'verified': true,
      'table_diameter_feet': 6,
      'seats_per_table': 10,
      'layout': [
        {'x': 20, 'y': 20},
      ],
      if (withKey) 'objects': objects,
    };

const _stage = StudioObject(
  id: 'obj-1',
  kind: StudioObjectKind.stage,
  description: 'Band stage',
  x: 30,
  y: 6,
  widthFeet: 16,
  depthFeet: 12,
);

void main() {
  group('StudioObject JSON', () {
    test('round-trips every field through toJson and fromJson', () {
      const object = StudioObject(
        id: 'obj-2',
        kind: StudioObjectKind.danceFloor,
        description: 'Dance floor',
        x: 12.5,
        y: 18,
        widthFeet: 20,
        depthFeet: 16,
        rotationDegrees: 90,
      );
      final json = object.toJson();
      expect(json, {
        'id': 'obj-2',
        'kind': 'dance_floor',
        'description': 'Dance floor',
        'x': 12.5,
        'y': 18.0,
        'widthFeet': 20.0,
        'depthFeet': 16.0,
        'rotationDegrees': 90.0,
      });
      final parsed = StudioObject.fromJson(json);
      expect(parsed.id, object.id);
      expect(parsed.kind, object.kind);
      expect(parsed.description, object.description);
      expect(parsed.x, object.x);
      expect(parsed.y, object.y);
      expect(parsed.widthFeet, object.widthFeet);
      expect(parsed.depthFeet, object.depthFeet);
      expect(parsed.rotationDegrees, object.rotationDegrees);
    });

    test('rotationDegrees defaults to 0 when absent', () {
      final parsed = StudioObject.fromJson({
        'id': 'obj-3',
        'kind': 'bar',
        'description': 'Bar',
        'x': 1,
        'y': 2,
        'widthFeet': 12,
        'depthFeet': 3,
      });
      expect(parsed.rotationDegrees, 0);
    });

    test('an unknown kind loads as a placeholder', () {
      final parsed = StudioObject.fromJson({
        'id': 'obj-4',
        'kind': 'hot_tub',
        'description': 'Hot tub',
        'x': 1,
        'y': 2,
        'widthFeet': 4,
        'depthFeet': 4,
      });
      expect(parsed.kind, StudioObjectKind.placeholder);
    });
  });

  group('FloorStudioLayout objects', () {
    test('fromJson reads the objects key beside the table layout', () {
      final layout = FloorStudioLayout.fromJson(
        _savedRow(objects: [_stage.toJson()]),
      );
      expect(layout.objects.single.id, 'obj-1');
      expect(layout.objects.single.kind, StudioObjectKind.stage);
      expect(layout.tables.single.x, 20);
      expect(layout.tables.length, 1);
    });

    test('a layout saved before objects existed loads with no objects', () {
      final layout = FloorStudioLayout.fromJson(
        _savedRow(withKey: false),
      );
      expect(layout.objects, isEmpty);
      expect(layout.tables.length, 1);
    });

    test('a null objects value loads as no objects', () {
      final layout = FloorStudioLayout.fromJson(_savedRow(objects: null));
      expect(layout.objects, isEmpty);
    });

    test(
        'toUpsertJson writes objects as their own key and keeps layout as tables',
        () {
      final layout = FloorStudioLayout(
        venueId: 'venue',
        floorPlanId: 'plan',
        widthFeet: 60,
        depthFeet: 40,
        verified: true,
        tables: const [StudioTable(20, 20)],
        objects: const [_stage],
      );
      final json = layout.toUpsertJson();
      expect(json['layout'], [
        {'x': 20.0, 'y': 20.0},
      ]);
      expect(json['objects'], [_stage.toJson()]);
    });

    test('a full round trip keeps tables and objects intact', () {
      final original = FloorStudioLayout(
        id: 'layout-1',
        venueId: 'venue',
        floorPlanId: 'plan',
        widthFeet: 60,
        depthFeet: 40,
        verified: false,
        tables: const [StudioTable(20, 20), StudioTable(40, 20)],
        objects: const [_stage],
      );
      final row = {
        'id': 'layout-1',
        'venue_id': 'venue',
        'floor_plan_id': 'plan',
        ...original.toUpsertJson(),
      };
      final parsed = FloorStudioLayout.fromJson(row);
      expect(
        parsed.tables.map((t) => (t.x, t.y)),
        [(20.0, 20.0), (40.0, 20.0)],
      );
      expect(parsed.objects.single.toJson(), _stage.toJson());
    });
  });

  group('studioObjectKindFor', () {
    final cases = <String, StudioObjectKind>{
      'stage': StudioObjectKind.stage,
      'Platform': StudioObjectKind.stage,
      'bar': StudioObjectKind.bar,
      'Bar counter': StudioObjectKind.bar,
      'dance floor': StudioObjectKind.danceFloor,
      'Dancefloor': StudioObjectKind.danceFloor,
      'DJ booth': StudioObjectKind.djBooth,
      'dj': StudioObjectKind.djBooth,
      'podium': StudioObjectKind.podium,
      'Lectern': StudioObjectKind.podium,
      'buffet': StudioObjectKind.buffet,
      'Dessert buffet': StudioObjectKind.buffet,
      'backdrop': StudioObjectKind.backdrop,
      'projector screen': StudioObjectKind.backdrop,
      'planter': StudioObjectKind.planter,
      'Plant': StudioObjectKind.planter,
      'something else': StudioObjectKind.placeholder,
      '': StudioObjectKind.placeholder,
    };
    cases.forEach((description, kind) {
      test('"$description" maps to ${kind.value}', () {
        expect(studioObjectKindFor(description), kind);
      });
    });

    test('matches whole words, so "adjacent" is not a DJ booth', () {
      expect(
        studioObjectKindFor('adjacent to the door'),
        StudioObjectKind.placeholder,
      );
      expect(
        studioObjectKindFor('bartender station'),
        StudioObjectKind.placeholder,
      );
    });
  });

  group('clampStudioObject', () {
    test('keeps the whole footprint inside the room', () {
      final clamped = clampStudioObject(
        _stage.copyWith(x: 0, y: 39),
        widthFeet: 60,
        depthFeet: 40,
      );
      expect(clamped.x, 8);
      expect(clamped.y, 34);
    });

    test('accounts for rotation when measuring the footprint', () {
      // A 16 x 12 stage turned 90 degrees is 12 wide and 16 deep on the plan.
      final clamped = clampStudioObject(
        _stage.copyWith(x: 1, y: 1, rotationDegrees: 90),
        widthFeet: 60,
        depthFeet: 40,
      );
      expect(clamped.x, closeTo(6, 1e-9));
      expect(clamped.y, closeTo(8, 1e-9));
    });

    test('centres an object wider than the room', () {
      final clamped = clampStudioObject(
        _stage.copyWith(x: 3, y: 3),
        widthFeet: 10,
        depthFeet: 40,
      );
      expect(clamped.x, 5);
      expect(clamped.y, 6);
    });

    test('leaves an object already inside the room alone', () {
      final clamped = clampStudioObject(
        _stage,
        widthFeet: 60,
        depthFeet: 40,
      );
      expect(clamped.x, 30);
      expect(clamped.y, 6);
    });
  });

  test('snapStudioFeet rounds to the nearest half foot', () {
    expect(snapStudioFeet(10.2), 10);
    expect(snapStudioFeet(10.3), 10.5);
    expect(snapStudioFeet(10.74), 10.5);
    expect(snapStudioFeet(10.76), 11);
  });

  group('studioObjectAt', () {
    test('finds the object under a point and misses empty floor', () {
      expect(studioObjectAt([_stage], 30, 6)?.id, 'obj-1');
      expect(studioObjectAt([_stage], 30, 13), isNull);
    });

    test('respects rotation', () {
      // Turned 90 degrees, the stage spans 6 ft either side in x and 8 ft in y.
      final turned = _stage.copyWith(rotationDegrees: 90);
      expect(studioObjectAt([turned], 30 + 5.5, 6)?.id, 'obj-1');
      expect(studioObjectAt([turned], 30 + 7, 6), isNull);
    });

    test('a later object is on top when two overlap', () {
      const other = StudioObject(
        id: 'obj-top',
        kind: StudioObjectKind.podium,
        description: 'Podium',
        x: 30,
        y: 6,
        widthFeet: 2,
        depthFeet: 2,
      );
      expect(studioObjectAt([_stage, other], 30, 6)?.id, 'obj-top');
    });
  });

  group('buildStudioSceneData objects', () {
    test('sends objects in meters and keeps the existing keys', () {
      final layout = FloorStudioLayout(
        venueId: 'venue',
        floorPlanId: 'plan',
        widthFeet: 60,
        depthFeet: 40,
        verified: true,
        tables: const [StudioTable(20, 20)],
        objects: const [
          StudioObject(
            id: 'obj-1',
            kind: StudioObjectKind.bar,
            description: 'Bar',
            x: 10,
            y: 4,
            widthFeet: 12,
            depthFeet: 3,
            rotationDegrees: 90,
          ),
        ],
      );
      final data = buildStudioSceneData(layout: layout, guestCount: 4);
      expect(
        data.keys,
        containsAll([
          'widthMeters',
          'heightMeters',
          'tableDiameterMeters',
          'seatsPerTable',
          'tables',
        ]),
      );
      expect(data['widthMeters'], closeTo(60 * 0.3048, 1e-9));
      final objects = data['objects']! as List;
      expect(objects, hasLength(1));
      final object = objects.single as Map<String, Object?>;
      expect(object['id'], 'obj-1');
      expect(object['kind'], 'bar');
      expect(object['description'], 'Bar');
      expect(object['x'], closeTo(10 * 0.3048, 1e-9));
      expect(object['y'], closeTo(4 * 0.3048, 1e-9));
      expect(object['widthMeters'], closeTo(12 * 0.3048, 1e-9));
      expect(object['depthMeters'], closeTo(3 * 0.3048, 1e-9));
      expect(object['rotationDegrees'], 90);
    });

    test('an empty object list is sent as an empty array', () {
      final data = buildStudioSceneData(
        layout: const FloorStudioLayout(
          venueId: 'venue',
          floorPlanId: 'plan',
          widthFeet: 60,
          depthFeet: 40,
          verified: true,
        ),
        guestCount: 0,
      );
      expect(data['objects'], isEmpty);
    });
  });
}
