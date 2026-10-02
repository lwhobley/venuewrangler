import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_providers.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/billing/presentation/billing_screen.dart';
import '../features/checklists/presentation/checklist_completion_screen.dart';
import '../features/checklists/presentation/checklist_list_screen.dart';
import '../features/ai/presentation/wrangler_assistant_screen.dart';
import '../features/dashboard/presentation/dashboard_screen.dart';
import '../features/events/presentation/event_list_screen.dart';
import '../features/floor/presentation/floor_plan_screen.dart';
import '../features/guests_reservations/presentation/reservations_screen.dart';
import '../features/incidents/presentation/incident_list_screen.dart';
import '../features/insights/presentation/shift_insights_screen.dart';
import '../features/integrations/presentation/integrations_screen.dart';
import '../features/inventory/presentation/inventory_list_screen.dart';
import '../features/notifications/presentation/notifications_screen.dart';
import '../features/organizations/presentation/organization_venue_switcher_screen.dart';
import '../features/pos/presentation/pos_management_screen.dart';
import '../features/schedules/presentation/schedule_list_screen.dart';
import '../features/settings/presentation/settings_screen.dart';
import '../features/staff_requests/presentation/staff_requests_screen.dart';
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

  return GoRouter(
    initialLocation: '/',
    redirect: (context, state) {
      final goingToSignIn = state.matchedLocation == '/sign-in';
      final goingToSelectVenue = state.matchedLocation == '/select-venue';

      if (!isSignedIn) {
        return goingToSignIn ? null : '/sign-in';
      }
      if (isSignedIn && goingToSignIn) return '/';
      if (!hasActiveVenue && !goingToSelectVenue) return '/select-venue';
      return null;
    },
    routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => const DashboardScreen(),
      ),
      GoRoute(
        path: '/sign-in',
        builder: (context, state) => const SignInScreen(),
      ),
      GoRoute(
        path: '/select-venue',
        builder: (context, state) => const OrganizationVenueSwitcherScreen(),
      ),
      GoRoute(
        path: '/tasks',
        builder: (context, state) => const TaskListScreen(),
      ),
      GoRoute(
        path: '/checklists',
        builder: (context, state) => const ChecklistListScreen(),
      ),
      GoRoute(
        path: '/checklists/:templateId',
        builder: (context, state) => ChecklistCompletionScreen(
          templateId: state.pathParameters['templateId']!,
          title: state.extra as String?,
        ),
      ),
      GoRoute(
        path: '/incidents',
        builder: (context, state) => const IncidentListScreen(),
      ),
      GoRoute(
        path: '/wrangler',
        builder: (context, state) => const WranglerAssistantScreen(),
      ),
      GoRoute(
        path: '/workforce',
        builder: (context, state) => const WorkforceRosterScreen(),
      ),
      GoRoute(
        path: '/inventory',
        builder: (context, state) => const InventoryListScreen(),
      ),
      GoRoute(
        path: '/schedules',
        builder: (context, state) => const ScheduleListScreen(),
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
        path: '/events',
        builder: (context, state) => const EventListScreen(),
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
        path: '/time-clock',
        builder: (context, state) => const TimeClockScreen(),
      ),
      GoRoute(
        path: '/notifications',
        builder: (context, state) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/reservations',
        builder: (context, state) => const ReservationsScreen(),
      ),
      GoRoute(
        path: '/floor',
        builder: (context, state) => const FloorPlanScreen(),
      ),
      GoRoute(
        path: '/pos',
        builder: (context, state) => const PosManagementScreen(),
      ),
      GoRoute(
        path: '/settings',
        builder: (context, state) => const SettingsScreen(),
      ),
    ],
  );
});
