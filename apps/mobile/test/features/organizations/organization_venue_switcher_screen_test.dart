import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/organizations/application/organizations_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/data/organizations_repository.dart';
import 'package:venuewrangler_mobile/features/organizations/domain/organization.dart';
import 'package:venuewrangler_mobile/features/organizations/presentation/organization_venue_switcher_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/data/venues_repository.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeOrganizationsRepository implements OrganizationsRepository {
  _FakeOrganizationsRepository(this.organizations);

  final List<Organization> organizations;

  @override
  Future<List<Organization>> fetchMyOrganizations() async => organizations;
}

class _FakeVenuesRepository implements VenuesRepository {
  _FakeVenuesRepository(this.venuesByOrg);

  final Map<String, List<Venue>> venuesByOrg;

  @override
  Future<List<Venue>> fetchVenuesForOrganization(String organizationId) async =>
      venuesByOrg[organizationId] ?? const [];
}

void main() {
  final org = Organization(id: 'org-1', name: 'Org One', createdAt: DateTime(2026));
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue One',
    createdAt: DateTime(2026),
  );

  testWidgets('shows an empty state when the user has no organizations', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          organizationsRepositoryProvider
              .overrideWithValue(_FakeOrganizationsRepository(const [])),
        ],
        child: const MaterialApp(home: OrganizationVenueSwitcherScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining("don't belong to any organization"), findsOneWidget);
  });

  testWidgets('lists organizations and their venues, and selecting a venue sets '
      'activeVenueProvider', (tester) async {
    late ProviderContainer container;

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
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
