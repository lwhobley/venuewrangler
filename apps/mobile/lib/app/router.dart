import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_providers.dart';
import 'app_shell.dart';
import '../features/auth/reset_password_screen.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/auth/sign_up_screen.dart';
import '../features/billing/presentation/billing_screen.dart';
import '../features/checklists/presentation/checklist_completion_screen.dart';
import '../features/checklists/presentation/checklist_list_screen.dart';
import '../features/chat/presentation/chat_screen.dart';
import '../features/crm/presentation/crm_screen.dart';
import '../features/documents/presentation/documents_screen.dart';
import '../features/ai/presentation/wrangler_assistant_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/dashboard/presentation/more_screen.dart';
import '../features/employee/presentation/employee_home_screen.dart';
import '../features/employee/presentation/profile_screen.dart';
import '../features/events/presentation/event_list_screen.dart';
import '../features/floor/presentation/floor_plan_editor_screen.dart';
import '../features/floor_studio/presentation/floor_studio_screen.dart';
import '../features/floor/presentation/floor_plan_screen.dart';
import '../features/guests_reservations/presentation/reservations_screen.dart';
import '../features/incidents/presentation/incident_list_screen.dart';
import '../features/handover/presentation/handover_screen.dart';
import '../features/insights/presentation/shift_insights_screen.dart';
import '../features/integrations/presentation/integration_complete_screen.dart';
import '../features/integrations/presentation/integrations_screen.dart';
import '../features/invites/application/invites_providers.dart';
import '../features/invites/presentation/pending_invites_screen.dart';
import '../features/inventory/presentation/inventory_list_screen.dart';
import '../features/mfa/presentation/mfa_challenge_screen.dart';
import '../features/mfa/presentation/mfa_settings_screen.dart';
import '../features/notifications/application/notification_routing.dart';
import '../features/notifications/application/notifications_providers.dart';
import '../features/notifications/presentation/notifications_screen.dart';
import '../features/organizations/presentation/organization_venue_switcher_screen.dart';
import '../features/pos/presentation/pos_management_screen.dart';
import '../features/schedules/presentation/schedule_list_screen.dart';
import '../features/schedules/presentation/schedule_timeline_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/shift_mode/presentation/shift_mode_screen.dart';
import '../features/staff_requests/presentation/staff_requests_screen.dart';
import '../features/tasks/presentation/task_board_screen.dart';
import '../features/tasks/presentation/task_list_screen.dart';
import '../features/team/domain/team_member.dart';
import '../features/team/presentation/team_screen.dart';
import '../features/time_clock/presentation/time_clock_screen.dart';
import '../features/venues/application/venues_providers.dart';
import '../features/venues/domain/venue.dart';
import '../features/workforce/presentation/workforce_roster_screen.dart';

/// Redirects between the auth flow, venue selection, and the authenticated app shell based
/// on [isSignedInProvider] and [activeVenueProvider]. Feature routes are added here as
/// Phase 2 builds them; this is deliberately the only router in the app so deep links and
/// push-notification routing (ported from the reference app's notification-to-tab mapping)
/// have one place to register.
/// Listenable notifier used by [routerProvider] to trigger redirects on auth/venue/role
/// updates without recreating the entire [GoRouter] and [NavigatorState] key.
class RouterRefreshNotifier extends ChangeNotifier {
  void notify() => notifyListeners();
}

final routerRefreshNotifierProvider = Provider<RouterRefreshNotifier>((ref) {
  final notifier = RouterRefreshNotifier();
  ref.listen(isSignedInProvider, (_, __) => notifier.notify());
  ref.listen(activeVenueProvider, (_, __) => notifier.notify());
  ref.listen(passwordRecoveryPendingProvider, (_, __) => notifier.notify());
  ref.listen(myVenueRoleProvider, (_, __) => notifier.notify());
  ref.listen(mfaChallengeRequiredProvider, (_, __) => notifier.notify());
  ref.listen(invitesPromptDueProvider, (_, __) => notifier.notify());
  ref.onDispose(notifier.dispose);
  return notifier;
});

/// Roles that get the full manager shell. Anything else (staff, no membership on the active
/// venue, or a role this app does not know such as `platform_admin`) gets the employee shell,
/// so an unexpected role never lands on manager screens. The database still enforces access.
const managerShellRoles = {
  'supervisor',
  'venue_manager',
  'organization_admin',
  'organization_owner',
};

/// True when [role] (already resolved) belongs in the employee shell.
bool usesEmployeeShell(String? role) => !managerShellRoles.contains(role);

final isEmployeeRoleProvider = Provider<bool>((ref) {
  final isSignedIn = ref.watch(isSignedInProvider);
  final hasActiveVenue = ref.watch(activeVenueProvider) != null;
  if (!isSignedIn || !hasActiveVenue) return false;
  final roleAsync = ref.watch(myVenueRoleProvider);
  if (roleAsync.hasError) return true;
  // Role not resolved yet: keep the structure the router already has (the redirect holds the
  // user on /loading) instead of building one shell now and swapping it a moment later.
  if (roleAsync.isLoading && !roleAsync.hasValue) return false;
  return usesEmployeeShell(roleAsync.valueOrNull);
});

final routerProvider = Provider<GoRouter>((ref) {
  // Only watch the employee boolean so the router structure stays completely stable across
  // ordinary venue switches, background refreshes, and role syncs.
  final employee = ref.watch(isEmployeeRoleProvider);
  final refreshNotifier = ref.watch(routerRefreshNotifierProvider);

  // Fresh per router instance.
  final rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

  final router = GoRouter(
    navigatorKey: rootKey,
    initialLocation: '/',
    refreshListenable: refreshNotifier,
    redirect: (context, state) {
      final isSignedIn = ref.read(isSignedInProvider);
      final hasActiveVenue = ref.read(activeVenueProvider) != null;
      final recoveringPassword = ref.read(passwordRecoveryPendingProvider);
      final roleAsync = isSignedIn && hasActiveVenue
          ? ref.read(myVenueRoleProvider)
          : const AsyncValue<String?>.data(null);
      final roleLoading = roleAsync.isLoading && !roleAsync.hasValue;
      final isEmployee =
          roleAsync.hasError || usesEmployeeShell(roleAsync.valueOrNull);

      final goingToSignIn = state.matchedLocation == '/sign-in';
      final goingToSignUp = state.matchedLocation == '/sign-up';
      final goingToSelectVenue = state.matchedLocation == '/select-venue';
      final goingToReset = state.matchedLocation == '/reset-password';
      final goingToMfaChallenge = state.matchedLocation == '/mfa-challenge';
      final goingToInvites = state.matchedLocation == '/invites';

      // A verified authenticator exists but this session only passed the password: nothing
      // else (not even a password-reset) until the code is entered.
      if (isSignedIn && ref.read(mfaChallengeRequiredProvider)) {
        return goingToMfaChallenge ? null : '/mfa-challenge';
      }
      if (goingToMfaChallenge) return '/';

      // Opened a reset link: nothing else until a new password is set.
      if (isSignedIn && recoveringPassword) {
        return goingToReset ? null : '/reset-password';
      }
      if (goingToReset) return '/';

      if (!isSignedIn) {
        return (goingToSignIn || goingToSignUp) ? null : '/sign-in';
      }
      if (isSignedIn && (goingToSignIn || goingToSignUp)) return '/';
      if (!hasActiveVenue) {
        if (goingToInvites) return null;
        if (!goingToSelectVenue) return '/select-venue';
        // Invites no longer auto-join at sign-up: someone invited who has no workspace yet is
        // shown them here once (until they decide later or accept).
        return ref.read(invitesPromptDueProvider) ? '/invites' : null;
      }

      // Choosing a venue (or creating a workspace) only sets the active venue; this router is
      // not rebuilt for it, so leave the switcher here. Stay only while a tapped notification
      // for a different venue is waiting for the person to switch to it.
      if (goingToSelectVenue) {
        final pending = ref.read(pendingNotificationRouteProvider);
        final awaitingSwitch = pending?.venueId != null &&
            pending!.venueId != ref.read(activeVenueProvider)?.id;
        if (!awaitingSwitch) return roleLoading ? '/loading' : '/';
        return null;
      }

      final path = state.uri.path;
      if (roleLoading) return path == '/loading' ? null : '/loading';
      if (path == '/loading') return '/';
      if (path == '/billing' &&
          roleAsync.valueOrNull != 'organization_owner' &&
          roleAsync.valueOrNull != 'organization_admin') {
        return '/';
      }
      if (path == '/team' &&
          !teamManagerRoles.contains(roleAsync.valueOrNull)) {
        return '/';
      }
      if (isEmployee && !employeeCanOpen(path)) return '/';
      return null;
    },
    routes: [
      // Outside the tab shell: auth, venue choice, and full-screen editors.
      GoRoute(
        path: '/sign-in',
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: '/sign-up',
        builder: (context, state) =>
            SignUpScreen(joiningTeam: state.uri.queryParameters['join'] == '1'),
      ),
      GoRoute(
        path: '/reset-password',
        builder: (context, state) => const ResetPasswordScreen(),
      ),
      GoRoute(
        path: '/select-venue',
        builder: (context, state) => const OrganizationVenueSwitcherScreen(),
      ),
      GoRoute(
        path: '/loading',
        builder: (context, state) => const _LoadingScreen(),
      ),
      GoRoute(
        path: '/invites',
        builder: (context, state) => const PendingInvitesScreen(),
      ),
      GoRoute(
        path: '/mfa',
        builder: (context, state) => const MfaSettingsScreen(),
      ),
      GoRoute(
        path: '/mfa-challenge',
        builder: (context, state) => const MfaChallengeScreen(),
      ),
      if (employee) _employeeShell() else _fullShell(rootKey),
    ],
  );
  ref.onDispose(router.dispose);
  return router;
});

/// Paths a team member may open; anything else sends them home.
@visibleForTesting
bool employeeCanOpen(String path) => const {
      '/',
      '/me',
      '/notifications',
      '/time-clock',
      '/schedules',
      '/schedules/timeline',
      '/floor',
      '/chat',
      '/staff-requests',
      '/sign-in',
      '/sign-up',
      '/select-venue',
      '/reset-password',
      '/loading',
      '/invites',
      '/mfa',
      '/mfa-challenge',
    }.contains(path);

class _LoadingScreen extends StatelessWidget {
  const _LoadingScreen();

  @override
  Widget build(BuildContext context) =>
      const Scaffold(body: Center(child: CircularProgressIndicator()));
}

StatefulShellRoute _employeeShell() {
  return StatefulShellRoute.indexedStack(
    builder: (context, state, shell) => AppShell(
      navigationShell: shell,
      destinations: AppShell.employeeDestinations,
    ),
    branches: [
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const EmployeeHomeScreen(),
          ),
          GoRoute(
            path: '/me',
            builder: (context, state) => const ProfileScreen(),
          ),
          GoRoute(
            path: '/notifications',
            builder: (context, state) => const NotificationsScreen(),
          ),
          GoRoute(
            path: '/staff-requests',
            builder: (context, state) => const StaffRequestsScreen(),
          ),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/time-clock',
            builder: (context, state) => const TimeClockScreen(),
          ),
        ],
      ),
      StatefulShellBranch(
        initialLocation: '/schedules/timeline',
        routes: [
          GoRoute(
            path: '/schedules',
            builder: (context, state) => const ScheduleListScreen(),
            routes: [
              GoRoute(
                path: 'timeline',
                builder: (context, state) => const ScheduleTimelineScreen(),
              ),
            ],
          ),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/floor',
            builder: (context, state) => const FloorPlanScreen(),
          ),
        ],
      ),
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/chat',
            builder: (context, state) => const ChatScreen(),
          ),
        ],
      ),
    ],
  );
}

StatefulShellRoute _fullShell(GlobalKey<NavigatorState> rootKey) {
  return StatefulShellRoute.indexedStack(
    builder: (context, state, shell) => AppShell(navigationShell: shell),
    branches: [
      // Home
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/',
            builder: (context, state) => const DashboardScreen(),
          ),
          GoRoute(
            path: '/shift',
            builder: (context, state) => const ShiftModeScreen(),
          ),
          GoRoute(
            path: '/notifications',
            builder: (context, state) => const NotificationsScreen(),
          ),
          GoRoute(
            path: '/handover',
            builder: (context, state) => const HandoverScreen(),
          ),
          GoRoute(
            path: '/wrangler',
            builder: (context, state) => const WranglerAssistantScreen(),
          ),
        ],
      ),
      // Floor
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/floor',
            builder: (context, state) => const FloorPlanScreen(),
            routes: [
              GoRoute(
                path: 'edit',
                parentNavigatorKey: rootKey,
                builder: (context, state) => const FloorPlanEditorScreen(),
              ),
              GoRoute(
                path: 'studio',
                parentNavigatorKey: rootKey,
                builder: (context, state) => FloorStudioScreen(
                  venueId: state.uri.queryParameters['venue'],
                  floorPlanId: state.uri.queryParameters['plan'],
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/reservations',
            builder: (context, state) => const ReservationsScreen(),
          ),
        ],
      ),
      // Schedule — opens on the board; /schedules is the list with swap requests.
      StatefulShellBranch(
        initialLocation: '/schedules/timeline',
        routes: [
          GoRoute(
            path: '/schedules',
            builder: (context, state) => const ScheduleListScreen(),
            routes: [
              GoRoute(
                path: 'timeline',
                builder: (context, state) => const ScheduleTimelineScreen(),
              ),
            ],
          ),
          GoRoute(
            path: '/time-clock',
            builder: (context, state) => const TimeClockScreen(),
          ),
          GoRoute(
            path: '/staff-requests',
            builder: (context, state) => const StaffRequestsScreen(),
          ),
          GoRoute(
            path: '/shift-insights',
            builder: (context, state) => ShiftInsightsScreen(
              shiftId: state.uri.queryParameters['shiftId'],
            ),
          ),
          GoRoute(
            path: '/workforce',
            builder: (context, state) => const WorkforceRosterScreen(),
          ),
        ],
      ),
      // Tasks — opens on the board; /tasks is the list view.
      StatefulShellBranch(
        initialLocation: '/tasks/board',
        routes: [
          GoRoute(
            path: '/tasks',
            builder: (context, state) => const TaskListScreen(),
            routes: [
              GoRoute(
                path: 'board',
                builder: (context, state) => const TaskBoardScreen(),
              ),
            ],
          ),
          GoRoute(
            path: '/checklists',
            builder: (context, state) => const ChecklistListScreen(),
            routes: [
              GoRoute(
                path: ':templateId',
                parentNavigatorKey: rootKey,
                builder: (context, state) => ChecklistCompletionScreen(
                  templateId: state.pathParameters['templateId']!,
                  title: state.extra as String?,
                ),
              ),
            ],
          ),
          GoRoute(
            path: '/incidents',
            builder: (context, state) => const IncidentListScreen(),
          ),
        ],
      ),
      // More
      StatefulShellBranch(
        routes: [
          GoRoute(
            path: '/more',
            builder: (context, state) => const MoreScreen(),
          ),
          GoRoute(
            path: '/chat',
            builder: (context, state) => const ChatScreen(),
          ),
          GoRoute(
            path: '/inventory',
            builder: (context, state) => const InventoryListScreen(),
          ),
          GoRoute(
            path: '/events',
            builder: (context, state) => const EventListScreen(),
          ),
          GoRoute(
            path: '/crm',
            builder: (context, state) => const CrmScreen(),
          ),
          GoRoute(
            path: '/documents',
            builder: (context, state) => const DocumentsScreen(),
          ),
          GoRoute(
            path: '/pos',
            builder: (context, state) => const PosManagementScreen(),
          ),
          GoRoute(
            path: '/billing',
            builder: (context, state) => const BillingScreen(),
          ),
          GoRoute(
            path: '/integrations',
            builder: (context, state) => const IntegrationsScreen(),
          ),
          // Return links from the {provider}-oauth callbacks (venuewrangler://integrations/...).
          GoRoute(
            path: '/integrations/connected',
            builder: (context, state) => IntegrationCompleteScreen(
              provider: state.uri.queryParameters['provider'],
              nonce: state.uri.queryParameters['nonce'],
            ),
          ),
          GoRoute(
            path: '/integrations/error',
            builder: (context, state) => IntegrationErrorScreen(
              reason: state.uri.queryParameters['reason'],
            ),
          ),
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
          ),
          GoRoute(
            path: '/team',
            builder: (context, state) => const TeamScreen(),
          ),
        ],
      ),
    ],
  );
}

/// Side-effect only, watched once at the app root (see app/app.dart) — starts
/// [NotificationTapService] and routes whatever `kind` it reports through
/// [routeForNotificationKind]. Lives here (not in notifications_providers.dart) specifically
/// so that file never has to import this one back: this router already depends on every
/// feature screen, including the notifications one.
class PendingNotificationRoute {
  const PendingNotificationRoute({required this.route, this.venueId});

  final String route;
  final String? venueId;
}

final pendingNotificationRouteProvider =
    StateProvider<PendingNotificationRoute?>((ref) => null);

final notificationTapRoutingProvider = Provider<void>((ref) {
  ref.watch(routerProvider);

  /// Delivers the pending notification when its venue is active. [fromTap] is true only for a
  /// freshly tapped notification: a different venue then sends the person to the switcher once.
  /// Re-delivery after a venue or role change never forces the switcher open again.
  void deliverPending({bool fromTap = false}) {
    if (!ref.read(isSignedInProvider) ||
        ref.read(activeVenueProvider) == null) {
      return;
    }
    final role = ref.read(myVenueRoleProvider);
    if (role.isLoading && !role.hasValue) return;
    final pending = ref.read(pendingNotificationRouteProvider);
    if (pending == null) return;
    final venue = ref.read(activeVenueProvider);
    if (pending.venueId != null && venue?.id != pending.venueId) {
      final router = ref.read(routerProvider);
      if (fromTap &&
          router.routeInformationProvider.value.uri.path != '/select-venue') {
        router.go('/select-venue');
      }
      return;
    }
    ref.read(pendingNotificationRouteProvider.notifier).state = null;
    ref.read(routerProvider).go(pending.route);
  }

  ref.listen<Venue?>(activeVenueProvider, (previous, next) {
    final pending = ref.read(pendingNotificationRouteProvider);
    // The person switched to a venue other than the one the notification belongs to: that
    // notification is no longer awaited, so drop it and let the switcher close.
    if (pending != null &&
        previous != null &&
        next != null &&
        pending.venueId != null &&
        next.id != pending.venueId) {
      ref.read(pendingNotificationRouteProvider.notifier).state = null;
      final router = ref.read(routerProvider);
      if (router.routeInformationProvider.value.uri.path == '/select-venue') {
        router.go('/');
      }
      return;
    }
    deliverPending();
  });
  ref.listen(myVenueRoleProvider, (_, __) => deliverPending());
  ref.listen(isSignedInProvider, (_, signedIn) {
    if (!signedIn) {
      ref.read(pendingNotificationRouteProvider.notifier).state = null;
    }
  });
  // ignore: unawaited_futures
  ref.read(notificationTapServiceProvider).start((data) {
    final kind = data['kind'] as String? ?? '';
    final route = routeForNotificationKind(kind);
    if (route == null) return;
    final notification = PendingNotificationRoute(
      route: route,
      venueId: data['venue_id'] as String?,
    );
    if (!ref.read(isSignedInProvider) ||
        ref.read(activeVenueProvider) == null) {
      ref.read(pendingNotificationRouteProvider.notifier).state = notification;
      return;
    }
    ref.read(pendingNotificationRouteProvider.notifier).state = notification;
    deliverPending(fromTap: true);
  });
});
