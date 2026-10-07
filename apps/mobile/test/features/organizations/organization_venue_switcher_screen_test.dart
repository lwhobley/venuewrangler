import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/application/organizations_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/data/organizations_repository.dart';
import 'package:venuewrangler_mobile/features/organizations/domain/organization.dart';
import 'package:venuewrangler_mobile/features/organizations/presentation/organization_venue_switcher_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/data/venues_repository.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeOrganizationsRepository implements OrganizationsRepository {
  _FakeOrganizationsRepository(this.organizations);

  List<Organization> organizations;

  /// Holds createWorkspace open while set, so the "creating" state can be observed.
  Completer<void>? gate;

  /// Errors thrown by successive createWorkspace calls, oldest first.
  final List<Object> failures = [];
  final List<({String name, String timezone})> created = [];

  @override
  Future<List<Organization>> fetchMyOrganizations() async => organizations;

  @override
  Future<({Organization organization, Venue venue})> createWorkspace({
    required String organizationName,
    required String venueName,
    String timezone = 'UTC',
  }) async {
    created.add((name: organizationName, timezone: timezone));
    await gate?.future;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    final org = Organization(
      id: 'org-new',
      name: organizationName,
      createdAt: DateTime(2026),
    );
    organizations = [org];
    return (
      organization: org,
      venue: Venue(
        id: 'venue-new',
        organizationId: org.id,
        name: venueName,
        createdAt: DateTime(2026),
      ),
    );
  }
}

class _FakeVenuesRepository implements VenuesRepository {
  _FakeVenuesRepository(this.venuesByOrg);

  final Map<String, List<Venue>> venuesByOrg;

  @override
  Future<List<Venue>> fetchVenuesForOrganization(String organizationId) async =>
      venuesByOrg[organizationId] ?? const [];
}

void main() {
  final org =
      Organization(id: 'org-1', name: 'Org One', createdAt: DateTime(2026));
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue One',
    createdAt: DateTime(2026),
  );

  testWidgets('shows an empty state when the user has no organizations',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'user-1'),
          organizationsRepositoryProvider
              .overrideWithValue(_FakeOrganizationsRepository(const [])),
        ],
        child: const MaterialApp(home: OrganizationVenueSwitcherScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.textContaining("don't belong to any organization"),
      findsOneWidget,
    );
    expect(find.text('Create your own workspace'), findsOneWidget);
  });

  Future<ProviderContainer> pumpEmpty(
    WidgetTester tester,
    _FakeOrganizationsRepository repo,
  ) async {
    late ProviderContainer container;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'user-1'),
          organizationsRepositoryProvider.overrideWithValue(repo),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(home: OrganizationVenueSwitcherScreen());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    return container;
  }

  Future<void> submitDialog(WidgetTester tester, String name) async {
    await tester.tap(find.text('Create your own workspace'));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.widgetWithText(TextFormField, 'Venue name'),
      name,
    );
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Central (Chicago)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump();
  }

  testWidgets('create-workspace dialog rejects an empty name', (tester) async {
    final repo = _FakeOrganizationsRepository(const []);
    await pumpEmpty(tester, repo);

    await tester.tap(find.text('Create your own workspace'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(find.text('Enter your venue name'), findsOneWidget);
    expect(repo.created, isEmpty);
  });

  testWidgets('creates a workspace, showing progress, then selects its venue',
      (tester) async {
    final repo = _FakeOrganizationsRepository(const [])
      ..gate = Completer<void>();
    final container = await pumpEmpty(tester, repo);

    await submitDialog(tester, 'Riverside Taphouse');
    await tester.pump();

    expect(find.text('Setting up your workspace…'), findsOneWidget);
    expect(repo.created.single.timezone, 'America/Chicago');

    repo.gate!.complete();
    await tester.pumpAndSettle();

    expect(container.read(activeVenueProvider)?.id, 'venue-new');
    expect(find.text('Setting up your workspace…'), findsNothing);
  });

  testWidgets('shows a failure and Try again creates the workspace',
      (tester) async {
    final repo = _FakeOrganizationsRepository(const [])
      ..failures.add(StateError('boom'));
    final container = await pumpEmpty(tester, repo);

    await submitDialog(tester, 'Riverside Taphouse');
    await tester.pumpAndSettle();

    expect(find.textContaining('try again'), findsOneWidget);
    expect(find.text('Try again'), findsOneWidget);
    expect(container.read(activeVenueProvider), isNull);

    await tester.tap(find.text('Try again'));
    await tester.pumpAndSettle();

    expect(repo.created, hasLength(2));
    expect(container.read(activeVenueProvider)?.id, 'venue-new');
  });

  testWidgets(
      'lists organizations and their venues, and selecting a venue sets '
      'activeVenueProvider', (tester) async {
    late ProviderContainer container;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'user-1'),
          organizationsRepositoryProvider
              .overrideWithValue(_FakeOrganizationsRepository([org])),
          venuesRepositoryProvider.overrideWithValue(
            _FakeVenuesRepository({
              'org-1': [venue],
            }),
          ),
        ],
        child: Consumer(
          builder: (context, ref, _) {
            container = ProviderScope.containerOf(context);
            return const MaterialApp(home: OrganizationVenueSwitcherScreen());
          },
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Org One'), findsOneWidget);
    expect(find.text('Venue One'), findsOneWidget);
    expect(container.read(activeVenueProvider), isNull);

    await tester.tap(find.text('Venue One'));
    await tester.pumpAndSettle();

    expect(container.read(activeVenueProvider), venue);
  });
}
