import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/app/router.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/application/organizations_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/domain/organization.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

void main() {
  final org = Organization(
    id: 'org-1',
    name: 'Loungeability',
    createdAt: DateTime(2026),
  );
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue One',
    createdAt: DateTime(2026),
  );
  final venueThree = Venue(
    id: 'venue-3',
    organizationId: 'org-1',
    name: 'Venue Three',
    createdAt: DateTime(2026),
  );

  ProviderContainer containerFor(String role, {List<Venue>? venues}) =>
      ProviderContainer(
        overrides: [
          isSignedInProvider.overrideWithValue(true),
          currentUserIdProvider.overrideWithValue('user-1'),
          myOrganizationsProvider.overrideWith((ref) async => [org]),
          venuesForOrganizationProvider
              .overrideWith((ref, organizationId) async => venues ?? [venue]),
          myVenueRoleProvider.overrideWith((ref) async => role),
        ],
      );

  Future<void> pumpApp(WidgetTester tester, ProviderContainer container) async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: Consumer(
          builder: (context, ref, _) {
            ref.watch(notificationTapRoutingProvider);
            return MaterialApp.router(routerConfig: ref.watch(routerProvider));
          },
        ),
      ),
    );
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  String location(ProviderContainer container) =>
      container.read(routerProvider).routeInformationProvider.value.uri.path;

  testWidgets('choosing a venue leaves the switcher for the home screen',
      (tester) async {
    final container = containerFor('organization_owner');
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    expect(location(container), '/select-venue');

    await tester.tap(find.text('Venue One'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(container.read(activeVenueProvider)?.id, 'venue-1');
    expect(location(container), '/');
  });

  testWidgets(
      'the switcher stays open while a notification for another venue waits',
      (tester) async {
    final container = containerFor('organization_owner');
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await tester.tap(find.text('Venue One'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(location(container), '/');

    container.read(pendingNotificationRouteProvider.notifier).state =
        const PendingNotificationRoute(route: '/tasks', venueId: 'venue-2');
    container.read(routerProvider).go('/select-venue');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(location(container), '/select-venue');
  });

  testWidgets(
      'picking a venue other than the notification venue clears the pending '
      'notification and leaves the switcher', (tester) async {
    final container =
        containerFor('organization_owner', venues: [venue, venueThree]);
    addTearDown(container.dispose);
    await pumpApp(tester, container);
    await tester.tap(find.text('Venue One'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(location(container), '/');

    container.read(pendingNotificationRouteProvider.notifier).state =
        const PendingNotificationRoute(route: '/tasks', venueId: 'venue-2');
    container.read(routerProvider).go('/select-venue');
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(location(container), '/select-venue');

    await tester.tap(find.text('Venue Three'));
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }

    expect(container.read(activeVenueProvider)?.id, 'venue-3');
    expect(container.read(pendingNotificationRouteProvider), isNull);
    expect(location(container), '/');
  });
}
