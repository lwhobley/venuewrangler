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
  String? requestedProvider;

  @override
  Future<String> requestConnection({
    required String venueId,
    required String provider,
  }) async {
    requestedProvider = provider;
    return 'new-connection';
  }

  @override
  Future<List<Map<String, dynamic>>> getCapabilities(
    String connectionId,
  ) async =>
      [];

  @override
  Future<List<Map<String, dynamic>>> getOutboundJobs(
    String connectionId,
  ) async =>
      [];

  @override
  Future<int> publishSchedule(String connectionId) async =>
      throw UnsupportedError('Not connected');

  @override
  Future<List<PosConnection>> getConnections({required String venueId}) async =>
      connections;

  @override
  Future<List<PosCheck>> getRecentChecks({
    required String venueId,
    int limit = 50,
  }) async =>
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

  testWidgets('renders empty state when no POS connections or checks exist',
      (tester) async {
    final fakeRepo =
        _FakePosRepository(initialConnections: [], initialChecks: []);

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

    expect(find.text('Integrations · POS'), findsOneWidget);
    expect(
      find.text(
        'No POS connection configured for this venue. Provider onboarding is required.',
      ),
      findsOneWidget,
    );
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

    expect(find.text('TOAST · restaurant'), findsOneWidget);
    expect(find.text('SETUP REQUIRED'), findsOneWidget);
    expect(find.text('Check #9876'), findsOneWidget);
    expect(find.text('Total: \$45.00 | Tip: \$8.00'), findsOneWidget);
  });

  testWidgets('does not offer unimplemented outbound 86 action',
      (tester) async {
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

    expect(find.text('86 Item (Toast)'), findsNothing);
    expect(fakeRepo.push86Called, isFalse);
  });

  testWidgets('records setup request without claiming provider access',
      (tester) async {
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
    await tester.scrollUntilVisible(find.text('Toast'), 250);
    await tester.tap(find.text('Toast'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Request setup').first);
    await tester.pumpAndSettle();
    expect(fakeRepo.requestedProvider, 'toast');
    expect(
      find.text(
        'Setup request recorded. Provider authorization is still required.',
      ),
      findsOneWidget,
    );
    expect(find.text('CONNECTED'), findsNothing);
  });
}
