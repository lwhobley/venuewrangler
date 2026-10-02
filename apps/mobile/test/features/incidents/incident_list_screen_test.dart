import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/features/incidents/application/incidents_providers.dart';
import 'package:venuewrangler_mobile/features/incidents/data/incidents_repository.dart';
import 'package:venuewrangler_mobile/features/incidents/domain/incident.dart';
import 'package:venuewrangler_mobile/features/incidents/presentation/incident_list_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _InMemoryOfflineQueueStore implements OfflineQueueStore {
  List<PendingMutation> saved = const [];

  @override
  Future<List<PendingMutation>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    saved = mutations;
  }
}

class _FakeIncidentsRepository implements IncidentsRepository {
  _FakeIncidentsRepository(this.incidents);

  List<Incident> incidents;
  bool simulateOffline = false;
  String? lastReportedTitle;
  String? lastResolvedId;

  @override
  Future<List<Incident>> fetchIncidentsForVenue(String venueId) async => incidents;

  @override
  Future<void> reportIncident({
    required String incidentId,
    required String venueId,
    required String title,
    String? description,
    required IncidentSeverity severity,
  }) async {
    if (simulateOffline) throw Exception('network unreachable');
    lastReportedTitle = title;
  }

  @override
  Future<void> updateStatus(String incidentId, IncidentStatus status) async {
    lastResolvedId = incidentId;
  }
}

void main() {
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue One',
    createdAt: DateTime(2026),
  );

  final openIncident = Incident(
    id: 'incident-1',
    venueId: 'venue-1',
    organizationId: 'org-1',
    title: 'Spilled drink at bar',
    severity: IncidentSeverity.low,
    status: IncidentStatus.open,
    createdAt: DateTime(2026),
  );

  List<Override> baseOverrides(_FakeIncidentsRepository fakeRepo) => [
        activeVenueProvider.overrideWith((ref) => venue),
        incidentsRepositoryProvider.overrideWithValue(fakeRepo),
        offlineQueueStoreProvider.overrideWithValue(_InMemoryOfflineQueueStore()),
      ];

  testWidgets('shows an empty state when there are no incidents', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(_FakeIncidentsRepository(const [])),
        child: const MaterialApp(home: IncidentListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No incidents reported.'), findsOneWidget);
  });

  testWidgets('lists incidents and resolving one calls the repository', (tester) async {
    final fakeRepo = _FakeIncidentsRepository([openIncident]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(fakeRepo),
        child: const MaterialApp(home: IncidentListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Spilled drink at bar'), findsOneWidget);

    await tester.tap(find.widgetWithText(TextButton, 'Resolve'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastResolvedId, 'incident-1');
  });

  testWidgets('reporting an incident online calls the repository', (tester) async {
    final fakeRepo = _FakeIncidentsRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(fakeRepo),
        child: const MaterialApp(home: IncidentListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Report incident'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'What happened?'), 'Broken glass');
    await tester.tap(find.widgetWithText(FilledButton, 'Report'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastReportedTitle, 'Broken glass');
  });

  testWidgets('reporting while offline queues the mutation and shows a syncing draft',
      (tester) async {
    final fakeRepo = _FakeIncidentsRepository([])..simulateOffline = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(fakeRepo),
        child: const MaterialApp(home: IncidentListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FloatingActionButton, 'Report incident'));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'What happened?'), 'Broken glass');
    await tester.tap(find.widgetWithText(FilledButton, 'Report'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastReportedTitle, isNull);
    expect(find.textContaining('Saved offline'), findsOneWidget);
    expect(find.text('Broken glass'), findsOneWidget);
    expect(find.text('Syncing…'), findsOneWidget);
  });
}
