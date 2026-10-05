import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/sign_out_service.dart';
import '../../events/application/events_providers.dart';
import '../../inventory/application/inventory_providers.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../tasks/application/tasks_providers.dart';
import '../../tasks/domain/operational_task.dart';
import '../../venues/application/venues_providers.dart';

/// The authenticated landing screen: a summary of the active venue's open tasks, today's
/// shifts, and upcoming events, each a stat tile that deep-links into its own feature screen
/// — plus the same quick-nav list the old placeholder home screen had, since not everything
/// belongs in a summary tile (Ask Wrangler, Billing, Integrations, Settings, …).
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeVenue = ref.watch(activeVenueProvider);

    if (activeVenue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final venueId = activeVenue.id;
    final tasksAsync = ref.watch(tasksForVenueProvider(venueId));
    final shiftsAsync = ref.watch(shiftsForVenueProvider(venueId));
    final eventsAsync = ref.watch(eventsForVenueProvider(venueId));
    final inventoryAsync = ref.watch(inventoryForVenueProvider(venueId));

    final openTaskCount = tasksAsync.maybeWhen(
      data: (tasks) => tasks.where((t) => t.status == TaskStatus.open).length,
      orElse: () => null,
    );
    final now = DateTime.now();
    final todayShiftCount = shiftsAsync.maybeWhen(
      data: (shifts) => shifts
          .where(
            (s) =>
                s.startTime.year == now.year &&
                s.startTime.month == now.month &&
                s.startTime.day == now.day,
          )
          .length,
      orElse: () => null,
    );
    final upcomingEventCount = eventsAsync.maybeWhen(
      data: (events) => events.where((e) => e.startTime.isAfter(now)).length,
      orElse: () => null,
    );
    final inventoryItemCount = inventoryAsync.maybeWhen(
      data: (items) => items.length,
      orElse: () => null,
    );

    return Scaffold(
      appBar: AppBar(
        title: Text(activeVenue.name),
        actions: [
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch venue',
            onPressed: () =>
                ref.read(activeVenueProvider.notifier).state = null,
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => signOutAndClearScopedData(ref),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(tasksForVenueProvider(venueId));
          ref.invalidate(shiftsForVenueProvider(venueId));
          ref.invalidate(eventsForVenueProvider(venueId));
          ref.invalidate(inventoryForVenueProvider(venueId));
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.4,
              children: [
                _StatTile(
                  label: 'Open tasks',
                  value: openTaskCount,
                  icon: Icons.checklist_outlined,
                  onTap: () => context.go('/tasks'),
                ),
                _StatTile(
                  label: "Today's shifts",
                  value: todayShiftCount,
                  icon: Icons.calendar_month_outlined,
                  onTap: () => context.go('/schedules'),
                ),
                _StatTile(
                  label: 'Upcoming events',
                  value: upcomingEventCount,
                  icon: Icons.event_outlined,
                  onTap: () => context.go('/events'),
                ),
                _StatTile(
                  label: 'Inventory items',
                  value: inventoryItemCount,
                  icon: Icons.inventory_2_outlined,
                  onTap: () => context.go('/inventory'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('More', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _NavTile(
              icon: Icons.handshake_outlined,
              label: 'CRM',
              route: '/crm',
            ),
            _NavTile(
              icon: Icons.folder_outlined,
              label: 'Documents',
              route: '/documents',
            ),
            _NavTile(
              icon: Icons.fact_check_outlined,
              label: 'Checklists',
              route: '/checklists',
            ),
            _NavTile(
              icon: Icons.report_outlined,
              label: 'Incidents',
              route: '/incidents',
            ),
            _NavTile(
              icon: Icons.auto_awesome_outlined,
              label: 'Ask Wrangler',
              route: '/wrangler',
            ),
            _NavTile(
              icon: Icons.groups_outlined,
              label: 'Staff',
              route: '/workforce',
            ),
            _NavTile(
              icon: Icons.timer_outlined,
              label: 'Time Clock',
              route: '/time-clock',
            ),
            _NavTile(
              icon: Icons.assignment_outlined,
              label: 'Staff Requests',
              route: '/staff-requests',
            ),
            _NavTile(
              icon: Icons.lightbulb_outlined,
              label: 'Shift Insights',
              route: '/shift-insights',
            ),
            _NavTile(
              icon: Icons.credit_card_outlined,
              label: 'Billing',
              route: '/billing',
            ),
            _NavTile(
              icon: Icons.extension_outlined,
              label: 'Integrations',
              route: '/integrations',
            ),
            _NavTile(
              icon: Icons.settings_outlined,
              label: 'Settings',
              route: '/settings',
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final int? value;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Icon(icon),
              Text(
                value?.toString() ?? '—',
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _NavTile extends StatelessWidget {
  const _NavTile({
    required this.icon,
    required this.label,
    required this.route,
  });

  final IconData icon;
  final String label;
  final String route;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(icon),
      title: Text(label),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.go(route),
    );
  }
}
