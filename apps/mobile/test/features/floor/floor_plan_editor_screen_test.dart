import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/floor/application/floor_editor_controller.dart';
import 'package:venuewrangler_mobile/features/floor/application/floor_providers.dart';
import 'package:venuewrangler_mobile/features/floor/data/floor_repository.dart';
import 'package:venuewrangler_mobile/features/floor/domain/editor_table.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_plan.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_table.dart';
import 'package:venuewrangler_mobile/features/floor/presentation/floor_plan_editor_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _Repo implements FloorRepository {
  List<EditorTable> created = [];
  List<EditorTable> updated = [];

  final now = DateTime(2026);

  @override
  Future<List<FloorPlan>> getFloorPlans({required String venueId}) async => [
        FloorPlan(
          id: 'plan',
          organizationId: 'org',
          venueId: venueId,
          name: 'Main',
          createdAt: now,
          updatedAt: now,
        ),
      ];

  @override
  Future<List<FloorTable>> getFloorTables({
    required String floorPlanId,
  }) async =>
      [
        FloorTable(
          id: 't1',
          organizationId: 'org',
          venueId: 'venue-1',
          floorPlanId: 'plan',
          label: 'T1',
          x: 200,
          y: 200,
          lastActivityAt: now,
          createdAt: now,
          updatedAt: now,
        ),
      ];

  @override
  Future<void> saveLayout({
    required String venueId,
    required String floorPlanId,
    required List<EditorTable> created,
    required List<EditorTable> updated,
    required List<String> removedIds,
  }) async {
    this.created = created;
    this.updated = updated;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime(2026),
  );

  Future<(ProviderContainer, _Repo)> pumpEditor(
    WidgetTester tester, {
    bool manager = true,
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final repo = _Repo();
    final container = ProviderContainer(
      overrides: [
        activeVenueProvider.overrideWith((ref) => venue),
        floorRepositoryProvider.overrideWithValue(repo),
        canManageActiveVenueProvider.overrideWith((ref) async => manager),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const FloorPlanEditorScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    return (container, repo);
  }

  testWidgets('dragging a table moves it, snapped, and publish sends the diff',
      (tester) async {
    final (container, repo) = await pumpEditor(tester);

    expect(find.text('T1'), findsOneWidget);
    expect(container.read(floorEditorProvider).hasChanges, isFalse);

    await tester.drag(find.text('T1'), const Offset(100, 60));
    await tester.pumpAndSettle();

    final moved = container.read(floorEditorProvider).tables.single;
    expect(moved.x, greaterThan(200));
    expect(moved.y, greaterThan(200));
    expect(moved.x % kGridUnit, 0);
    expect(container.read(floorEditorProvider).selectedId, 't1');

    await tester.tap(find.text('Publish'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Publish').last);
    await tester.pumpAndSettle();

    expect(repo.updated.single.id, 't1');
    expect(repo.created, isEmpty);
  });

  testWidgets('add table flow creates and selects a new table', (tester) async {
    final (container, _) = await pumpEditor(tester);

    await tester.tap(find.text('Add table'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final state = container.read(floorEditorProvider);
    expect(state.tables, hasLength(2));
    expect(state.selected?.isNew, isTrue);
    expect(find.text('Edit table'), findsNothing);
    expect(find.byTooltip('Edit table'), findsOneWidget);
  });

  testWidgets('non-managers are told only managers can edit the layout',
      (tester) async {
    await pumpEditor(tester, manager: false);

    expect(
      find.text('Only managers can edit the floor layout.'),
      findsOneWidget,
    );
    expect(find.text('T1'), findsNothing);
    expect(find.text('Add table'), findsNothing);
  });
}
