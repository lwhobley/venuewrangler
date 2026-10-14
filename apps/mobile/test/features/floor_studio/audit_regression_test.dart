import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/features/floor/application/floor_providers.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_plan.dart';
import 'package:venuewrangler_mobile/features/floor_studio/application/floor_studio_providers.dart';
import 'package:venuewrangler_mobile/features/floor_studio/data/floor_studio_repository.dart';
import 'package:venuewrangler_mobile/features/floor_studio/domain/floor_studio.dart';
import 'package:venuewrangler_mobile/features/floor_studio/presentation/floor_studio_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

const stage = StudioObject(
  id: 'stage',
  kind: StudioObjectKind.stage,
  description: 'Stage',
  x: 30,
  y: 20,
  widthFeet: 16,
  depthFeet: 12,
);
final venue = Venue(
  id: 'venue',
  organizationId: 'org',
  name: 'Venue',
  createdAt: DateTime(2026),
);
FloorPlan plan(String id) => FloorPlan(
      id: id,
      organizationId: 'org',
      venueId: 'venue',
      name: id,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  test('objects must fit the room and clear dining tables', () {
    expect(
      validateStudioLayout(
        widthFeet: 10,
        depthFeet: 10,
        tableDiameterFeet: 6,
        tables: [],
        objects: [stage],
      ),
      isNotEmpty,
    );
    expect(
      validateStudioLayout(
        widthFeet: 60,
        depthFeet: 40,
        tableDiameterFeet: 6,
        tables: [const StudioTable(30, 20)],
        objects: [stage],
      ),
      isNotEmpty,
    );
    expect(
      validateStudioLayout(
        widthFeet: 60,
        depthFeet: 40,
        tableDiameterFeet: 6,
        tables: [const StudioTable(10, 10)],
        objects: [stage],
      ),
      isEmpty,
    );
  });

  test('rotated object footprints cannot overlap each other', () {
    expect(
      validateStudioLayout(
        widthFeet: 60,
        depthFeet: 40,
        tableDiameterFeet: 6,
        tables: [],
        objects: [stage, stage.copyWith(rotationDegrees: 45)],
      ),
      isNotEmpty,
    );
    expect(
      validateStudioLayout(
        widthFeet: 80,
        depthFeet: 60,
        tableDiameterFeet: 6,
        tables: [],
        objects: [stage, stage.copyWith(x: 60, rotationDegrees: 45)],
      ),
      isEmpty,
    );
  });

  test('generated candidates respect placed objects', () {
    final options = generateStudioLayouts(
      widthFeet: 80,
      depthFeet: 60,
      guestCount: 10,
      objects: [stage.copyWith(x: 10, y: 10)],
    );
    for (final option in options) {
      expect(
        validateStudioLayout(
          widthFeet: 80,
          depthFeet: 60,
          tableDiameterFeet: 6,
          tables: option.tables,
          objects: [stage.copyWith(x: 10, y: 10)],
        ),
        isEmpty,
      );
    }
  });

  test('one malformed saved plan does not hide healthy plans', () async {
    Map<String, dynamic> row(String id, Object layout) => {
          'id': id,
          'venue_id': 'venue',
          'floor_plan_id': id,
          'width_feet': 60,
          'depth_feet': 40,
          'verified': true,
          'table_diameter_feet': 6,
          'seats_per_table': 10,
          'layout': layout,
          'objects': [],
        };
    final client = SupabaseClient(
      'https://example.test',
      'test-key',
      httpClient: MockClient(
        (request) async => http.Response(
          jsonEncode([
            row('broken', [{}]),
            row('healthy', [
              {'x': 10, 'y': 10},
            ]),
          ]),
          200,
          request: request,
          headers: {'content-type': 'application/json'},
        ),
      ),
    );
    addTearDown(client.dispose);
    final layouts = await SupabaseFloorStudioRepository(client)
        .getLayouts(venueId: 'venue');
    expect(layouts.first.loadError, isNotNull);
    expect(layouts.last.loadError, isNull);
    expect(layouts.last.tables.single.x, 10);
  });

  testWidgets(
      'layout load failure blocks edits and retry loads saved measurements',
      (tester) async {
    var fail = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          canManageActiveVenueProvider.overrideWith((ref) async => true),
          floorPlansProvider.overrideWith((ref) async => [plan('ballroom')]),
          floorStudioLayoutsProvider.overrideWith((ref, venueId) async {
            if (fail) throw StateError('offline');
            return [
              const FloorStudioLayout(
                id: 'saved',
                venueId: 'venue',
                floorPlanId: 'ballroom',
                widthFeet: 60,
                depthFeet: 40,
                verified: true,
                objects: [stage],
              ),
            ];
          }),
        ],
        child: const MaterialApp(home: FloorStudioScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Retry before editing'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    fail = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Width (feet)'))
          .controller!
          .text,
      '60.0',
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('BEO target selects its room instead of the first room',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          canManageActiveVenueProvider.overrideWith((ref) async => true),
          floorPlansProvider
              .overrideWith((ref) async => [plan('ballroom'), plan('terrace')]),
          floorStudioLayoutsProvider.overrideWith(
            (ref, venueId) async => [
              const FloorStudioLayout(
                venueId: 'venue',
                floorPlanId: 'ballroom',
                widthFeet: 60,
                depthFeet: 40,
                verified: true,
              ),
              const FloorStudioLayout(
                venueId: 'venue',
                floorPlanId: 'terrace',
                widthFeet: 90,
                depthFeet: 50,
                verified: true,
              ),
            ],
          ),
        ],
        child: const MaterialApp(
          home: FloorStudioScreen(venueId: 'venue', floorPlanId: 'terrace'),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      tester
          .widget<TextField>(find.widgetWithText(TextField, 'Width (feet)'))
          .controller!
          .text,
      '90.0',
    );
  });

  testWidgets('BEO target refuses to edit a different active venue',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
        ],
        child: const MaterialApp(
          home: FloorStudioScreen(
            venueId: 'another-venue',
            floorPlanId: 'terrace',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('Switch to the order'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
  });
}
