import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../core/auth/auth_providers.dart';
import '../features/auth/sign_in_screen.dart';
import '../features/billing/presentation/billing_screen.dart';
import '../features/checklists/presentation/checklist_completion_screen.dart';
import '../features/checklists/presentation/checklist_list_screen.dart';
import '../features/ai/presentation/wrangler_assistant_screen.dart';
import '../features/dashboard/placeholder_home_screen.dart';
import '../features/incidents/presentation/incident_list_screen.dart';
import '../features/inventory/presentation/inventory_list_screen.dart';
import '../features/organizations/presentation/organization_venue_switcher_screen.dart';
import '../features/schedules/presentation/schedule_list_screen.dart';
import '../features/tasks/presentation/task_list_screen.dart';
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
        builder: (context, state) => const PlaceholderHomeScreen(),
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
    ],
  );
});
