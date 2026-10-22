import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/app/router.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/invites/application/invites_providers.dart';
import 'package:venuewrangler_mobile/features/invites/domain/pending_invite.dart';
import 'package:venuewrangler_mobile/features/organizations/application/organizations_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/domain/organization.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

import '../features/mfa/fake_mfa_repository.dart';

void main() {
  final org = Organization(id: 'org-1', name: 'Org', createdAt: DateTime(2026));
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue One',
    createdAt: DateTime(2026),
  );

  group('role allowlist (audit A-07)', () {
    test('only supervisor and up get the manager shell', () {
      for (final role in [
        'supervisor',
        'venue_manager',
        'organization_admin',
        'organization_owner',
      ]) {
        expect(usesEmployeeShell(role), isFalse, reason: role);
      }
      for (final role in [
        'staff',
        null,
        'platform_admin',
        'something_new',
        '',
      ]) {
        expect(usesEmployeeShell(role), isTrue, reason: '$role');
      }
    });

    ProviderContainer containerFor(Future<String?> Function() role) {
      final container = ProviderContainer(
        overrides: [
          isSignedInProvider.overrideWithValue(true),
          mfaChallengeRequiredProvider.overrideWithValue(false),
          myVenueRoleProvider.overrideWith((ref) => role()),
          activeVenueProvider.overrideWith((ref) => venue),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<bool> managerShellFor(String? role) async {
      final container = containerFor(() async => role);
      await container.read(myVenueRoleProvider.future);
      final router = container.read(routerProvider);
      return router.configuration
          .findMatch(Uri.parse('/more'))
          .matches
          .isNotEmpty;
    }

    test('unknown, missing and platform_admin roles get the employee shell',
        () async {
      expect(await managerShellFor('supervisor'), isTrue);
      expect(await managerShellFor('venue_manager'), isTrue);
      expect(await managerShellFor('organization_owner'), isTrue);
      expect(await managerShellFor('staff'), isFalse);
      expect(await managerShellFor(null), isFalse);
      expect(await managerShellFor('platform_admin'), isFalse);
    });

    test(
        'while the role is still loading the structure does not flip to the '
        'employee shell', () async {
      final gate = Completer<String?>();
      final container = containerFor(() => gate.future);
      // Start resolving.
      container.listen(myVenueRoleProvider, (_, __) {});

      expect(container.read(isEmployeeRoleProvider), isFalse);

      gate.complete('venue_manager');
      await container.read(myVenueRoleProvider.future);
      expect(container.read(isEmployeeRoleProvider), isFalse);
    });

    test('a failed role lookup falls back to the employee shell', () async {
      final container = containerFor(() async => throw StateError('boom'));
      container.listen(myVenueRoleProvider, (_, __) {});
      await container
          .read(myVenueRoleProvider.future)
          .then((_) {}, onError: (_) {});

      expect(container.read(isEmployeeRoleProvider), isTrue);
    });
  });

  group('redirects', () {
    final mfaRequired = StateProvider<bool>((ref) => false);

    ProviderContainer containerFor({
      Future<String?> Function()? role,
      Venue? activeVenue,
      List<Organization> organizations = const [],
      List<PendingInvite> invites = const [],
    }) {
      final container = ProviderContainer(
        overrides: [
          isSignedInProvider.overrideWithValue(true),
          currentUserIdProvider.overrideWithValue('user-1'),
          mfaChallengeRequiredProvider
              .overrideWith((ref) => ref.watch(mfaRequired)),
          mfaRepositoryProvider.overrideWithValue(FakeMfaRepository()),
          myOrganizationsProvider.overrideWith((ref) async => organizations),
          venuesForOrganizationProvider
              .overrideWith((ref, organizationId) async => [venue]),
          pendingInvitesProvider.overrideWith((ref) async => invites),
          myVenueRoleProvider
              .overrideWith((ref) => (role ?? () async => 'venue_manager')()),
          activeVenueProvider.overrideWith((ref) => activeVenue),
        ],
      );
      addTearDown(container.dispose);
      return container;
    }

    Future<void> pumpApp(
      WidgetTester tester,
      ProviderContainer container,
    ) async {
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: Consumer(
            builder: (context, ref, _) {
              ref.watch(notificationTapRoutingProvider);
              return MaterialApp.router(
                routerConfig: ref.watch(routerProvider),
              );
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

    PendingInvite invite() => const PendingInvite(
          inviteId: 'i1',
          organizationId: 'org-9',
          organizationName: 'Harbor Group',
          venueId: 'venue-9',
          venueName: 'The Pier',
          role: 'staff',
        );

    testWidgets('holds the user on /mfa-challenge until the code is accepted',
        (tester) async {
      final container = containerFor(
        activeVenue: venue,
        organizations: [org],
      );
      container.read(mfaRequired.notifier).state = true;
      await pumpApp(tester, container);
      expect(location(container), '/mfa-challenge');

      container.read(routerProvider).go('/settings');
      for (var i = 0; i < 4; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(location(container), '/mfa-challenge');

      container.read(mfaRequired.notifier).state = false;
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(location(container), '/');
    });

    testWidgets('an invited user with no workspace is shown the invites',
        (tester) async {
      final container = containerFor(invites: [invite()]);
      await pumpApp(tester, container);

      expect(location(container), '/invites');
      expect(find.text('The Pier'), findsOneWidget);
    });

    testWidgets('invites are not forced on someone who already has a workspace',
        (tester) async {
      final container = containerFor(
        organizations: [org],
        invites: [invite()],
      );
      await pumpApp(tester, container);

      expect(location(container), '/select-venue');
      // The switcher offers them instead.
      expect(find.textContaining("You're invited to join"), findsOneWidget);
    });

    testWidgets('Decide later returns to the switcher without looping back',
        (tester) async {
      final container = containerFor(invites: [invite()]);
      await pumpApp(tester, container);
      expect(location(container), '/invites');

      await tester.tap(find.text('Decide later'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(location(container), '/select-venue');
    });

    testWidgets('with no invites the switcher is not interrupted',
        (tester) async {
      final container = containerFor();
      await pumpApp(tester, container);

      expect(location(container), '/select-venue');
    });

    testWidgets('waits on /loading until the role resolves, then goes home',
        (tester) async {
      final gate = Completer<String?>();
      final container = containerFor(
        role: () => gate.future,
        activeVenue: venue,
        organizations: [org],
      );
      await pumpApp(tester, container);
      expect(location(container), '/loading');

      gate.complete('venue_manager');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(location(container), '/');
    });

    testWidgets('supervisors cannot open the team screen, managers can',
        (tester) async {
      final supervisor = containerFor(
        role: () async => 'supervisor',
        activeVenue: venue,
        organizations: [org],
      );
      await pumpApp(tester, supervisor);
      supervisor.read(routerProvider).go('/team');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(location(supervisor), '/');
    });

    testWidgets('managers reach the team screen', (tester) async {
      final manager = containerFor(
        activeVenue: venue,
        organizations: [org],
      );
      await pumpApp(tester, manager);
      manager.read(routerProvider).go('/team');
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(location(manager), '/team');
    });
  });
}
