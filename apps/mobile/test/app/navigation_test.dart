import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:venuewrangler_mobile/app/app_shell.dart';
import 'package:venuewrangler_mobile/app/router.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

/// Every in-app link target (context.go/push, notification routing, More screen items).
/// If a screen is linked from somewhere, it has to exist in the router.
const _linked = [
  '/',
  '/shift',
  '/notifications',
  '/wrangler',
  '/floor',
  '/floor/edit',
  '/reservations',
  '/schedules',
  '/schedules/timeline',
  '/time-clock',
  '/staff-requests',
  '/shift-insights',
  '/workforce',
  '/tasks',
  '/tasks/board',
  '/checklists',
  '/checklists/some-template',
  '/incidents',
  '/more',
  '/chat',
  '/inventory',
  '/events',
  '/crm',
  '/documents',
  '/pos',
  '/billing',
  '/integrations',
  '/settings',
  '/sign-in',
  '/select-venue',
  '/reset-password',
];

void main() {
  test('every linked location resolves to a route', () async {
    final container = ProviderContainer(
      overrides: [
        isSignedInProvider.overrideWithValue(true),
        myVenueRoleProvider.overrideWith((ref) async => 'venue_manager'),
        activeVenueProvider.overrideWith(
          (ref) => Venue(
            id: 'v',
            organizationId: 'o',
            name: 'Venue',
            createdAt: DateTime(2026),
          ),
        ),
      ],
    );
    addTearDown(container.dispose);
    await container.read(myVenueRoleProvider.future);
    final router = container.read(routerProvider);

    for (final path in _linked) {
      final match = router.configuration.findMatch(Uri.parse(path));
      expect(match.isError, isFalse, reason: '$path has no route');
      expect(match.matches, isNotEmpty, reason: '$path has no route');
    }
  });

  testWidgets('the tab bar switches sections and keeps each tab\'s place',
      (tester) async {
    Widget page(String name, {String? pushTo}) => Builder(
          builder: (context) => Scaffold(
            appBar: AppBar(title: Text(name)),
            body: pushTo == null
                ? const SizedBox()
                : TextButton(
                    onPressed: () => context.push(pushTo),
                    child: const Text('open detail'),
                  ),
          ),
        );

    final router = GoRouter(
      initialLocation: '/',
      routes: [
        StatefulShellRoute.indexedStack(
          builder: (context, state, shell) => AppShell(navigationShell: shell),
          branches: [
            StatefulShellBranch(
              routes: [GoRoute(path: '/', builder: (_, __) => page('Home'))],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(
                  path: '/floor',
                  builder: (_, __) => page('Floor page', pushTo: '/floor/x'),
                  routes: [
                    GoRoute(path: 'x', builder: (_, __) => page('Detail')),
                  ],
                ),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/s', builder: (_, __) => page('Schedule page')),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/t', builder: (_, __) => page('Tasks page')),
              ],
            ),
            StatefulShellBranch(
              routes: [
                GoRoute(path: '/m', builder: (_, __) => page('More page')),
              ],
            ),
          ],
        ),
      ],
    );
    addTearDown(router.dispose);

    await tester.pumpWidget(
      MaterialApp.router(theme: AppTheme.dark(), routerConfig: router),
    );
    expect(find.text('Home'), findsWidgets);
    expect(find.byType(NavigationBar), findsOneWidget);

    await tester.tap(find.text('Floor'));
    await tester.pumpAndSettle();
    expect(find.text('Floor page'), findsOneWidget);

    await tester.tap(find.text('open detail'));
    await tester.pumpAndSettle();
    expect(find.text('Detail'), findsOneWidget);
    // Pushed detail keeps the tab bar and gets a back arrow.
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.byType(BackButton), findsOneWidget);

    await tester.tap(find.text('Schedule'));
    await tester.pumpAndSettle();
    expect(find.text('Schedule page'), findsOneWidget);

    // Returning to Floor restores where you were…
    await tester.tap(find.text('Floor'));
    await tester.pumpAndSettle();
    expect(find.text('Detail'), findsOneWidget);

    // …and tapping it again pops back to the tab's first screen.
    await tester.tap(find.text('Floor'));
    await tester.pumpAndSettle();
    expect(find.text('Floor page'), findsOneWidget);
  });

  group('employee app', () {
    Future<GoRouter> employeeRouter() async {
      final container = ProviderContainer(
        overrides: [
          isSignedInProvider.overrideWithValue(true),
          myVenueRoleProvider.overrideWith((ref) async => 'staff'),
          activeVenueProvider.overrideWith(
            (ref) => Venue(
              id: 'v',
              organizationId: 'o',
              name: 'Venue',
              createdAt: DateTime(2026),
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      await container.read(myVenueRoleProvider.future);
      return container.read(routerProvider);
    }

    test('has exactly the employee screens', () async {
      final router = await employeeRouter();
      for (final path in [
        '/',
        '/me',
        '/notifications',
        '/time-clock',
        '/schedules',
        '/schedules/timeline',
        '/floor',
        '/chat',
        '/staff-requests',
      ]) {
        expect(
          router.configuration.findMatch(Uri.parse(path)).isError,
          isFalse,
          reason: '$path should exist for employees',
        );
      }
      for (final path in [
        '/more',
        '/tasks/board',
        '/floor/edit',
        '/crm',
        '/billing',
        '/inventory',
        '/settings',
      ]) {
        expect(
          router.configuration.findMatch(Uri.parse(path)).matches,
          isEmpty,
          reason: '$path should not exist for employees',
        );
      }
    });

    test('anything outside the employee screens redirects home', () {
      expect(employeeCanOpen('/floor'), isTrue);
      expect(employeeCanOpen('/me'), isTrue);
      expect(employeeCanOpen('/floor/edit'), isFalse);
      expect(employeeCanOpen('/staff-requests'), isTrue);
      expect(employeeCanOpen('/more'), isFalse);
    });

    test('staff get the employee app; supervisors and up do not', () {
      expect(isEmployeeRole('staff'), isTrue);
      expect(isEmployeeRole('supervisor'), isFalse);
      expect(isEmployeeRole('venue_manager'), isFalse);
      expect(isEmployeeRole('organization_owner'), isFalse);
    });
  });
}
