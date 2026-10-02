import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/floor/application/floor_providers.dart';
import 'package:venuewrangler_mobile/features/floor/data/floor_repository.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_plan.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_table.dart';
import 'package:venuewrangler_mobile/features/floor/presentation/floor_plan_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeFloorRepository implements FloorRepository {
  _FakeFloorRepository({List<FloorTable>? initialTables})
      : _tables = initialTables ?? [],
        _controller = StreamController<List<FloorTable>>.broadcast() {
    _controller.add(_tables);
  }

  final List<FloorTable> _tables;
  final StreamController<List<FloorTable>> _controller;
  bool updateStatusCalled = false;
  String? lastUpdatedStatus;
  bool mergeTablesCalled = false;

  @override
  Future<List<FloorPlan>> getFloorPlans({required String venueId}) async => [];

  @override
  Future<List<FloorTable>> getFloorTables({required String floorPlanId}) async => _tables;

  @override
  Stream<List<FloorTable>> streamFloorTables({required String venueId}) => _controller.stream;

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
      _controller.add(_tables);
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
        ],
        child: const MaterialApp(home: FloorPlanScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('Floor Plan'), findsOneWidget);
    expect(find.text('No tables found for this venue'), findsOneWidget);
  });

  testWidgets('renders tables and allows updating status via action sheet', (tester) async {
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
}
