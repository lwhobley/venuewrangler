import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/pos/application/pos_providers.dart';
import 'package:venuewrangler_mobile/features/pos/data/pos_repository.dart';
import 'package:venuewrangler_mobile/features/pos/domain/pos_check.dart';
import 'package:venuewrangler_mobile/features/pos/domain/pos_connection.dart';
import 'package:venuewrangler_mobile/features/pos/presentation/pos_management_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakePosRepository implements PosRepository {
  _FakePosRepository({
    List<PosConnection>? initialConnections,
    List<PosCheck>? initialChecks,
  })  : connections = initialConnections ?? [],
        checks = initialChecks ?? [];

  final List<PosConnection> connections;
  final List<PosCheck> checks;
  bool push86Called = false;
  String? pushedItemGuid;
  bool? pushedAvailability;

  @override
  Future<List<PosConnection>> getConnections({required String venueId}) async => connections;

  @override
  Future<List<PosCheck>> getRecentChecks({required String venueId, int limit = 50}) async =>
      checks;

  @override
  Future<void> push86Item({
    required String venueId,
    required String itemGuid,
    required bool isAvailable,
  }) async {
    push86Called = true;
    pushedItemGuid = itemGuid;
    pushedAvailability = isAvailable;
  }
}

void main() {
  final testVenue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime.now(),
  );

  testWidgets('renders empty state when no POS connections or checks exist', (tester) async {
    final fakeRepo = _FakePosRepository(initialConnections: [], initialChecks: []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          posRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: PosManagementScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('POS Management'), findsOneWidget);
    expect(find.text('No active POS connections found for this venue.'), findsOneWidget);
    expect(find.text('No recent checks received from POS.'), findsOneWidget);
  });

  testWidgets('renders POS connection and checks feed', (tester) async {
    final fakeRepo = _FakePosRepository(
      initialConnections: [
        PosConnection(
          id: 'conn-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          provider: 'toast',
          status: 'active',
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
      initialChecks: [
        PosCheck(
          id: 'chk-1',
          organizationId: 'org-1',
          venueId: 'venue-1',
          provider: 'toast',
          externalCheckId: '9876',
          tableLabel: 'Table 4',
          totalCents: 4500,
          tipCents: 800,
          openedAt: DateTime.now(),
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          posRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: PosManagementScreen()),
      ),
    );

    await tester.pumpAndSettle();

    expect(find.text('TOAST'), findsOneWidget);
    expect(find.text('CONNECTED'), findsOneWidget);
    expect(find.text('Check #9876'), findsOneWidget);
    expect(find.text('Total: \$45.00 | Tip: \$8.00'), findsOneWidget);
  });

  testWidgets('triggers outbound 86 dialog and pushes command', (tester) async {
    final fakeRepo = _FakePosRepository();

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          posRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: PosManagementScreen()),
      ),
    );

    await tester.pumpAndSettle();

    final btn86 = find.text('86 Item (Toast)');
    expect(btn86, findsOneWidget);

    await tester.tap(btn86);
    await tester.pumpAndSettle();

    expect(find.text('Update Item Availability (86)'), findsOneWidget);

    // Enter item GUID
    await tester.enterText(find.byType(TextField), 'toast-item-ribeye');
    await tester.pumpAndSettle();

    // Tap Send to POS
    await tester.tap(find.text('Send to POS'));
    await tester.pumpAndSettle();

    expect(fakeRepo.push86Called, isTrue);
    expect(fakeRepo.pushedItemGuid, 'toast-item-ribeye');
    expect(fakeRepo.pushedAvailability, isFalse);
  });
}
