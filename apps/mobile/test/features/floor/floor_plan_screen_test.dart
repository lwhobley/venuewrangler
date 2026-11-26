import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/features/floor/application/floor_providers.dart';
import 'package:venuewrangler_mobile/features/floor/data/floor_repository.dart';
import 'package:venuewrangler_mobile/features/floor/domain/editor_table.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_permissions.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_plan.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_table.dart';
import 'package:venuewrangler_mobile/features/floor/presentation/floor_plan_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeFloorRepository implements FloorRepository {
  _FakeFloorRepository({List<FloorTable>? initialTables})
      : _tables = initialTables ?? [];

  final List<FloorTable> _tables;
  bool updateStatusCalled = false;
  String? lastUpdatedStatus;
  bool mergeTablesCalled = false;

  @override
  Future<List<FloorPlan>> getFloorPlans({required String venueId}) async => [];

  @override
  Future<List<FloorTable>> getFloorTables({
    required String floorPlanId,
  }) async =>
      _tables;

  @override
  Future<FloorPlan> createFloorPlan({
    required String venueId,
    required String name,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> saveLayout({
    required String venueId,
    required String floorPlanId,
    required List<EditorTable> created,
    required List<EditorTable> updated,
    required List<String> removedIds,
  }) async {}

  @override
  Stream<List<FloorTable>> streamFloorTables({required String venueId}) async* {
    yield _tables;
  }

  @override
  Future<void> updateTableStatus({
    required String venueId,
    required String tableId,
    required String status,
  }) async {
    updateStatusCalled = true;
    lastUpdatedStatus = status;
    final idx = _tables.indexWhere((t) => t.id == tableId);
    if (idx != -1) {
      final old = _tables[idx];
      _tables[idx] = FloorTable(
        id: old.id,
        organizationId: old.organizationId,
        venueId: old.venueId,
        floorPlanId: old.floorPlanId,
        label: old.label,
        shape: old.shape,
        capacity: old.capacity,
        status: status,
        lastActivityAt: DateTime.now(),
        createdAt: old.createdAt,
        updatedAt: DateTime.now(),
      );
    }
  }

  @override
  Future<String> mergeTables({
    required String venueId,
    required List<String> tableIds,
    int? partySize,
  }) async {
    mergeTablesCalled = true;
    return 'merge-123';
  }

  @override
  Future<void> splitTables({
    required String venueId,
    required String mergeGroupId,
  }) async {}

  @override
  Future<void> assignTables({
    required String venueId,
    required List<String> tableIds,
    required String reservationId,
    String holdType = 'seated',
  }) async {}
}

void main() {
  final testVenue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime.now(),
  );

  testWidgets('renders empty state when no tables exist', (tester) async {
    final fakeRepo = _FakeFloorRepository(initialTables: []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          floorRepositoryProvider.overrideWithValue(fakeRepo),
          canManageActiveVenueProvider.overrideWith((ref) async => false),
        ],
        child: const MaterialApp(home: FloorPlanScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Floor Plan'), findsOneWidget);
    expect(find.text('No tables found for this venue'), findsOneWidget);
  });

  testWidgets('renders tables and allows updating status via action sheet',
      (tester) async {
    final fakeRepo = _FakeFloorRepository(
      initialTables: [
        FloorTable(
          id: 'tbl-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          floorPlanId: 'fp-1',
          label: 'T10',
          capacity: 4,
          status: 'available',
          lastActivityAt: DateTime.now(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          floorRepositoryProvider.overrideWithValue(fakeRepo),
          canManageActiveVenueProvider.overrideWith((ref) async => false),
        ],
        child: const MaterialApp(home: FloorPlanScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('T10'), findsOneWidget);
    expect(find.text('AVAILABLE'), findsOneWidget);

    // Tap table to open action sheet
    await tester.tap(find.text('T10'));
    await tester.pumpAndSettle();

    expect(find.text('Mark Seated'), findsOneWidget);

    // Tap Mark Seated
    await tester.tap(find.text('Mark Seated'));
    await tester.pumpAndSettle();

    expect(fakeRepo.updateStatusCalled, isTrue);
    expect(fakeRepo.lastUpdatedStatus, 'seated');
  });

  group('merge and split are supervisor and above', () {
    test('role check fails closed', () {
      for (final role in [
        'supervisor',
        'venue_manager',
        'organization_admin',
        'organization_owner',
      ]) {
        expect(canMergeOrSplitTables(role), isTrue, reason: role);
      }
      for (final role in ['staff', null, 'platform_admin']) {
        expect(canMergeOrSplitTables(role), isFalse, reason: '$role');
      }
    });

    test('a 42501 from merge or split explains the role requirement', () {
      const denied = PostgrestException(message: 'forbidden', code: '42501');
      expect(
        floorActionErrorMessage(denied, mergeOrSplit: true),
        'Only supervisors and managers can merge or split tables.',
      );
      expect(
        floorActionErrorMessage(denied),
        "You don't have permission to change this table.",
      );
      expect(
        floorActionErrorMessage(Exception('offline'), mergeOrSplit: true),
        'Could not update the floor. Please try again.',
      );
    });

    FloorTable table(String id, String label, {String? mergeGroupId}) =>
        FloorTable(
          id: id,
          organizationId: 'org-1',
          venueId: 'venue-1',
          floorPlanId: 'fp-1',
          label: label,
          capacity: 4,
          status: 'available',
          mergeGroupId: mergeGroupId,
          lastActivityAt: DateTime(2026),
          createdAt: DateTime(2026),
          updatedAt: DateTime(2026),
        );

    Future<void> pumpAs(WidgetTester tester, String role) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeVenueProvider.overrideWith((ref) => testVenue),
            floorRepositoryProvider.overrideWithValue(
              _FakeFloorRepository(
                initialTables: [
                  table('t1', 'T1', mergeGroupId: 'm1'),
                  table('t2', 'T2', mergeGroupId: 'm1'),
                  table('t3', 'T3'),
                ],
              ),
            ),
            canManageActiveVenueProvider.overrideWith((ref) async => false),
            myVenueRoleProvider.overrideWith((ref) async => role),
          ],
          child: const MaterialApp(home: FloorPlanScreen()),
        ),
      );
      await tester.pumpAndSettle();
    }

    testWidgets('staff cannot select tables to merge or see split',
        (tester) async {
      await pumpAs(tester, 'staff');

      // No multi-select for staff: a long press just opens the table's actions.
      await tester.longPress(find.text('T3'));
      await tester.pumpAndSettle();
      expect(find.text('Table T3'), findsOneWidget);
      expect(find.byTooltip('Clear Selection'), findsNothing);
      expect(find.byTooltip('Merge Selected Tables'), findsNothing);
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();

      await tester.tap(find.text('T1'));
      await tester.pumpAndSettle();
      expect(find.text('Mark Seated'), findsOneWidget);
      expect(find.text('Split Merged Tables'), findsNothing);
    });

    testWidgets('supervisors can merge and split', (tester) async {
      await pumpAs(tester, 'supervisor');

      await tester.longPress(find.text('T3'));
      await tester.longPress(find.text('T2'));
      await tester.pumpAndSettle();
      expect(find.byTooltip('Merge Selected Tables'), findsOneWidget);

      await tester.tap(find.byTooltip('Clear Selection'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('T1'));
      await tester.pumpAndSettle();
      expect(find.text('Split Merged Tables'), findsOneWidget);
    });
  });
}
