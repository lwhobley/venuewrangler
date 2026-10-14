import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/floor/application/floor_providers.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_plan.dart';
import 'package:venuewrangler_mobile/features/floor_studio/application/floor_studio_providers.dart';
import 'package:venuewrangler_mobile/features/floor_studio/data/floor_studio_repository.dart';
import 'package:venuewrangler_mobile/features/floor_studio/domain/floor_studio.dart';
import 'package:venuewrangler_mobile/features/floor_studio/presentation/floor_studio_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

/// In-memory stand-in for the Supabase repository. Saved layouts are what the screen reloads.
class _FakeFloorStudioRepository implements FloorStudioRepository {
  final saved = <FloorStudioLayout>[];

  @override
  Future<List<FloorStudioLayout>> getLayouts({required String venueId}) async =>
      [...saved];

  @override
  Future<void> saveLayout(FloorStudioLayout layout) async {
    saved
      ..removeWhere((l) => l.floorPlanId == layout.floorPlanId)
      ..add(layout);
  }

  @override
  Future<int?> reservationPartySizeForBeo({required String beoId}) async =>
      null;
}

final _venue = Venue(
  id: 'venue-1',
  organizationId: 'org-1',
  name: 'Main hall',
  createdAt: DateTime(2026),
);

final _plan = FloorPlan(
  id: 'plan-1',
  organizationId: 'org-1',
  venueId: 'venue-1',
  name: 'Ballroom',
  createdAt: DateTime(2026),
  updatedAt: DateTime(2026),
);

Future<_FakeFloorStudioRepository> _pumpScreen(WidgetTester tester) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);

  final repo = _FakeFloorStudioRepository();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeVenueProvider.overrideWith((ref) => _venue),
        canManageActiveVenueProvider.overrideWith((ref) async => true),
        floorPlansProvider.overrideWith((ref) async => [_plan]),
        floorStudioRepositoryProvider.overrideWithValue(repo),
        floorStudioLayoutsProvider.overrideWith(
          (ref, venueId) => repo.getLayouts(venueId: venueId),
        ),
      ],
      child: const MaterialApp(home: FloorStudioScreen()),
    ),
  );
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Width (feet)'),
    '60',
  );
  await tester.enterText(
    find.widgetWithText(TextField, 'Depth (feet)'),
    '40',
  );
  // The plan adopts typed dimensions after a short pause.
  await tester.pump(const Duration(seconds: 1));
  return repo;
}

Future<void> _addPodium(WidgetTester tester) async {
  await tester.tap(find.text('Add object'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.widgetWithText(TextField, 'Description'),
    'Podium',
  );
  await tester.tap(find.widgetWithText(FilledButton, 'Add'));
  await tester.pumpAndSettle();
}

Future<void> _saveLayout(WidgetTester tester) async {
  await tester.tap(find.text('Save floor plan layout'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('add, move, save, then remove an object', (tester) async {
    final repo = await _pumpScreen(tester);

    // Add a stage from the form. Its kind follows the description.
    await tester.tap(find.text('Add object'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Band stage',
    );
    await tester.pump();
    expect(find.text('Kind: Stage'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    expect(find.text('Selected: Band stage'), findsOneWidget);
    expect(find.widgetWithText(ListTile, 'Band stage'), findsOneWidget);

    // Move it: the stage starts in the middle of the room (30 ft, 20 ft). The canvas is
    // 9 px per foot here, so a 54 px drag right is 6 ft, and 36 px down is 4 ft.
    final canvas = find.byKey(const ValueKey('studio-object-plan-canvas'));
    await tester.drag(canvas, const Offset(54, 0));
    await tester.pump();
    await tester.drag(canvas, const Offset(0, 36));
    await tester.pumpAndSettle();

    await _saveLayout(tester);
    expect(repo.saved, hasLength(1));
    final moved = repo.saved.single.objects.single;
    expect(moved.description, 'Band stage');
    expect(moved.kind, StudioObjectKind.stage);
    expect(moved.x, closeTo(36, 1e-9));
    expect(moved.y, closeTo(24, 1e-9));

    // Remove it, with confirmation, then save.
    await tester.tap(find.widgetWithText(ListTile, 'Band stage'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Remove'));
    await tester.pumpAndSettle();
    expect(find.text('Remove Band stage?'), findsOneWidget);
    await tester.tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.widgetWithText(FilledButton, 'Remove'),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.widgetWithText(ListTile, 'Band stage'), findsNothing);

    await _saveLayout(tester);
    expect(repo.saved.single.objects, isEmpty);
  });

  testWidgets('an object dragged past the room edge is clamped inside it',
      (tester) async {
    final repo = await _pumpScreen(tester);

    await tester.tap(find.text('Add object'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextField, 'Description'),
      'Podium',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    // A 2 ft podium starts at the centre. Dragging far right stops at the wall (59 ft).
    await tester.drag(
      find.byKey(const ValueKey('studio-object-plan-canvas')),
      const Offset(900, 0),
    );
    await tester.pumpAndSettle();
    await _saveLayout(tester);
    expect(repo.saved.single.objects.single.x, closeTo(59, 1e-9));
  });

  testWidgets(
      'shrinking the room moves objects inside the new walls, ignoring '
      'half-typed values', (tester) async {
    final repo = await _pumpScreen(tester);
    await _addPodium(tester);
    await tester.drag(
      find.byKey(const ValueKey('studio-object-plan-canvas')),
      const Offset(900, 0),
    );
    await tester.pumpAndSettle();

    // "6" on the way to "40" must not shrink the room: that would clamp the podium to 5 ft.
    final width = find.widgetWithText(TextField, 'Width (feet)');
    await tester.enterText(width, '6');
    await tester.pump(const Duration(milliseconds: 100));
    await tester.enterText(width, '40');
    await tester.pump(const Duration(seconds: 1));

    expect(find.textContaining('Podium'), findsWidgets);
    await _saveLayout(tester);
    expect(repo.saved.single.widthFeet, 40);
    expect(repo.saved.single.objects.single.x, closeTo(39, 1e-9));
  });

  testWidgets('a non-finite width is rejected, not drawn', (tester) async {
    final repo = await _pumpScreen(tester);
    await _addPodium(tester);
    await tester.enterText(
      find.widgetWithText(TextField, 'Width (feet)'),
      'Infinity',
    );
    await tester.pump(const Duration(seconds: 1));

    expect(tester.takeException(), isNull);
    expect(
      find.byKey(const ValueKey('studio-object-plan-canvas')),
      findsOneWidget,
    );
    await _saveLayout(tester);
    expect(find.text('Enter room width and depth.'), findsOneWidget);
    expect(repo.saved, isEmpty);
  });
}
