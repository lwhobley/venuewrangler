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
import '../features/floor/presentation/floor_plan_screen.dart';
import '../features/guests_reservations/presentation/reservations_screen.dart';
import '../features/incidents/presentation/incident_list_screen.dart';
import '../features/insights/presentation/shift_insights_screen.dart';
import '../features/integrations/presentation/integrations_screen.dart';
import '../features/inventory/presentation/inventory_list_screen.dart';
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
import '../features/time_clock/presentation/time_clock_screen.dart';
import '../features/venues/application/venues_providers.dart';
import '../features/workforce/presentation/workforce_roster_screen.dart';

/// Redirects between the auth flow, venue selection, and the authenticated app shell based
/// on [isSignedInProvider] and [activeVenueProvider]. Feature routes are added here as
/// Phase 2 builds them; this is deliberately the only router in the app so deep links and
/// push-notification routing (ported from the reference app's notification-to-tab mapping)
/// have one place to register.
final routerProvider = Provider<GoRouter>((ref) {
  final isSignedIn = ref.watch(isSignedInProvider);
  final hasActiveVenue = ref.watch(activeVenueProvider) != null;
  final recoveringPassword = ref.watch(passwordRecoveryPendingProvider);
  // Which app to show depends on the user's role at the active venue. Until it's known we
  // hold on a loading screen, so a team member never glimpses the manager app.
  final roleAsync = isSignedIn && hasActiveVenue
      ? ref.watch(myVenueRoleProvider)
      : const AsyncValue<String?>.data(null);
  final roleLoading = roleAsync.isLoading && !roleAsync.hasValue;
  // If the role can't be read (e.g. offline at launch), fall back to the least-privileged
  // view; pulling to refresh on Home retries.
  final employee = roleAsync.hasError || isEmployeeRole(roleAsync.valueOrNull);

  // Fresh per router instance (the router is rebuilt when auth/venue state changes).
  final rootKey = GlobalKey<NavigatorState>(debugLabel: 'root');

  return GoRouter(
    navigatorKey: rootKey,
    initialLocation: '/',
    redirect: (context, state) {
      final goingToSignIn = state.matchedLocation == '/sign-in';
      final goingToSignUp = state.matchedLocation == '/sign-up';
      final goingToSelectVenue = state.matchedLocation == '/select-venue';
      final goingToReset = state.matchedLocation == '/reset-password';

      // Opened a reset link: nothing else until a new password is set.
      if (isSignedIn && recoveringPassword) {
        return goingToReset ? null : '/reset-password';
      }
      if (goingToReset) return '/';

      if (!isSignedIn) {
        return (goingToSignIn || goingToSignUp) ? null : '/sign-in';
      }
      if (isSignedIn && (goingToSignIn || goingToSignUp)) return '/';
      if (!hasActiveVenue && !goingToSelectVenue) return '/select-venue';
      if (!hasActiveVenue) return null;

      final path = state.uri.path;
      if (roleLoading) return path == '/loading' ? null : '/loading';
      if (path == '/loading') return '/';
      if (employee && !employeeCanOpen(path)) return '/';
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
        builder: (context, state) => const SignUpScreen(),
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
      if (employee) _employeeShell() else _fullShell(rootKey),
    ],
  );
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
      '/sign-in',
      '/sign-up',
      '/select-venue',
      '/reset-password',
      '/loading',
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
          GoRoute(
            path: '/settings',
            builder: (context, state) => const SettingsScreen(),
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
final notificationTapRoutingProvider = Provider<void>((ref) {
  final router = ref.watch(routerProvider);
  // ignore: unawaited_futures
  ref.read(notificationTapServiceProvider).start((data) {
    final kind = data['kind'] as String? ?? '';
    final route = routeForNotificationKind(kind);
    if (route != null) router.go(route);
  });
});
