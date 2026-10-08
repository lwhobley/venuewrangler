import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/ops_colors.dart';
import '../../events/application/events_providers.dart';
import '../../inventory/application/inventory_providers.dart';
import '../../notifications/application/notifications_providers.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../tasks/application/tasks_providers.dart';
import '../../tasks/domain/operational_task.dart';
import '../../venues/application/venues_providers.dart';

const _weekdays = [
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];
const _months = [
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];

/// Home tab: today at a glance, the way into shift mode, and one-tap jumps to the places
/// people go most. Everything else lives under the More tab.
class DashboardScreen extends ConsumerWidget {
  const DashboardScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeVenue = ref.watch(activeVenueProvider);

    if (activeVenue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final theme = Theme.of(context);
    final venueId = activeVenue.id;
    final tasksAsync = ref.watch(tasksForVenueProvider(venueId));
    final shiftsAsync = ref.watch(shiftsForVenueProvider(venueId));
    final eventsAsync = ref.watch(eventsForVenueProvider(venueId));
    final inventoryAsync = ref.watch(inventoryForVenueProvider(venueId));
    final unread = ref.watch(unreadNotificationsCountProvider);

    final openTaskCount = tasksAsync.maybeWhen(
      data: (tasks) => tasks
          .where(
            (t) =>
                t.status == TaskStatus.open ||
                t.status == TaskStatus.inProgress,
          )
          .length,
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
      data: (items) => items.where((item) => item.active).length,
      orElse: () => null,
    );

    final greeting = now.hour < 12
        ? 'Good morning'
        : now.hour < 17
            ? 'Good afternoon'
            : 'Good evening';

    return Scaffold(
      appBar: AppBar(
        title: Text(activeVenue.name),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            onPressed: () => context.push('/notifications'),
            icon: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: const Icon(Icons.notifications_outlined),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.swap_horiz),
            tooltip: 'Switch venue',
            onPressed: () =>
                ref.read(activeVenueProvider.notifier).state = null,
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
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
          children: [
            Text(greeting, style: theme.textTheme.headlineSmall),
            Text(
              '${_weekdays[now.weekday - 1]}, ${_months[now.month - 1]} ${now.day}',
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            _ShiftModeCard(onTap: () => context.push('/shift')),
            const SizedBox(height: 20),
            const _SectionLabel('Today'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.6,
              children: [
                _StatTile(
                  label: 'Open tasks',
                  value: openTaskCount,
                  icon: Icons.view_kanban_outlined,
                  onTap: () => context.go('/tasks/board'),
                ),
                _StatTile(
                  label: "Today's shifts",
                  value: todayShiftCount,
                  icon: Icons.calendar_month_outlined,
                  onTap: () => context.go('/schedules/timeline'),
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
            const SizedBox(height: 20),
            const _SectionLabel('Jump to'),
            GridView.count(
              crossAxisCount: 3,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.05,
              children: [
                _JumpTile(
                  icon: Icons.table_restaurant_outlined,
                  label: 'Floor plan',
                  onTap: () => context.go('/floor'),
                ),
                _JumpTile(
                  icon: Icons.view_timeline_outlined,
                  label: 'Schedule',
                  onTap: () => context.go('/schedules/timeline'),
                ),
                _JumpTile(
                  icon: Icons.view_kanban_outlined,
                  label: 'Task board',
                  onTap: () => context.go('/tasks/board'),
                ),
                _JumpTile(
                  icon: Icons.timer_outlined,
                  label: 'Time clock',
                  onTap: () => context.go('/time-clock'),
                ),
                _JumpTile(
                  icon: Icons.event_seat_outlined,
                  label: 'Reservations',
                  onTap: () => context.go('/reservations'),
                ),
                _JumpTile(
                  icon: Icons.report_outlined,
                  label: 'Incidents',
                  onTap: () => context.go('/incidents'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  const _SectionLabel(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: Text(
        text.toUpperCase(),
        style: Theme.of(context)
            .textTheme
            .labelSmall
            ?.copyWith(letterSpacing: 0.8),
      ),
    );
  }
}

class _ShiftModeCard extends StatelessWidget {
  const _ShiftModeCard({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.primary,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              Icon(Icons.badge_outlined, size: 32, color: scheme.onPrimary),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Shift mode',
                      style: Theme.of(context)
                          .textTheme
                          .titleMedium
                          ?.copyWith(color: scheme.onPrimary),
                    ),
                    Text(
                      'Your shift, clock status and tasks in one place',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onPrimary),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: scheme.onPrimary),
            ],
          ),
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
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.ops.panelBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Row(
                children: [
                  Icon(icon, size: 20, color: theme.colorScheme.primary),
                  const Spacer(),
                  Icon(
                    Icons.chevron_right,
                    size: 18,
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
              Text(
                value?.toString() ?? '—',
                style: theme.textTheme.headlineMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
              Text(label, style: theme.textTheme.bodySmall),
            ],
          ),
        ),
      ),
    );
  }
}

class _JumpTile extends StatelessWidget {
  const _JumpTile({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(14),
        side: BorderSide(color: context.ops.panelBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 28, color: theme.colorScheme.primary),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                maxLines: 2,
                style: theme.textTheme.labelMedium,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
