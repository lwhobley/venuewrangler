import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/offline/offline_queue_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../notifications/application/notifications_providers.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../tasks/application/task_status_change.dart';
import '../../tasks/application/tasks_providers.dart';
import '../../tasks/domain/operational_task.dart';
import '../../time_clock/application/time_clock_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../domain/shift_mode.dart';
import 'shift_widgets.dart';

/// A phone-first, one-handed home for someone who is on shift: what they're working, whether
/// they're clocked in, what's on their plate, and the few things they reach for most — all
/// with large touch targets and nothing that needs precision.
class ShiftModeScreen extends ConsumerStatefulWidget {
  const ShiftModeScreen({super.key});

  @override
  ConsumerState<ShiftModeScreen> createState() => _ShiftModeScreenState();
}

class _ShiftModeScreenState extends ConsumerState<ShiftModeScreen> {
  late final Timer _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
    // Keeps countdowns and the clocked-in timer fresh without refetching anything.
    _ticker = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() => _now = DateTime.now());
    });
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  Future<void> _refresh(String venueId) async {
    ref.invalidate(shiftsForVenueProvider(venueId));
    ref.invalidate(tasksForVenueProvider(venueId));
    ref.invalidate(activeTimeEntryProvider(venueId));
    await ref.read(shiftsForVenueProvider(venueId).future);
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }
    final userId = ref.watch(currentUserIdProvider);
    final shiftsAsync = ref.watch(shiftsForVenueProvider(venue.id));
    final tasksAsync = ref.watch(tasksForVenueProvider(venue.id));
    final clockAsync = ref.watch(activeTimeEntryProvider(venue.id));
    final queue = ref.watch(offlineQueueControllerProvider);
    final pending = pendingTaskStatuses(queue.pending);
    final unread = ref.watch(unreadNotificationsCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Shift mode'),
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(venue.id),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(
              venue.name,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
            const SizedBox(height: 12),
            shiftsAsync.when(
              loading: () => const CardShell(
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => ErrorState(
                message: 'Could not load your shifts.',
                onRetry: () => ref.invalidate(shiftsForVenueProvider(venue.id)),
              ),
              data: (shifts) =>
                  ShiftCard(mine: myShifts(shifts, userId, _now), now: _now),
            ),
            const SizedBox(height: 12),
            ClockCard(entry: clockAsync, now: _now),
            const SizedBox(height: 20),
            SectionTitle(
              'My tasks',
              trailing: TextButton(
                onPressed: () => context.go('/tasks/board'),
                child: const Text('See all'),
              ),
            ),
            tasksAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => ErrorState(
                message: 'Could not load tasks.',
                onRetry: () => ref.invalidate(tasksForVenueProvider(venue.id)),
              ),
              data: (tasks) {
                final mine = myOpenTasks(tasks, userId, pending, _now);
                if (mine.isEmpty) {
                  return const CardShell(
                    child: EmptyState(
                      icon: Icons.task_alt,
                      message: "You're all caught up.",
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final t in mine.take(6))
                      MyTaskRow(
                        task: t,
                        now: _now,
                        syncing: pending.containsKey(t.id),
                        onDone: () => changeTaskStatus(
                          ref,
                          ScaffoldMessenger.of(context),
                          t,
                          TaskStatus.completed,
                        ),
                      ),
                    if (mine.length > 6)
                      Padding(
                        padding: const EdgeInsets.only(top: 4),
                        child: Text('+${mine.length - 6} more'),
                      ),
                  ],
                );
              },
            ),
            const SizedBox(height: 20),
            const SectionTitle('Quick actions'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.7,
              children: [
                _ActionTile(
                  icon: Icons.table_restaurant_outlined,
                  label: 'Floor',
                  onTap: () => context.go('/floor'),
                ),
                _ActionTile(
                  icon: Icons.report_problem_outlined,
                  label: 'Report incident',
                  onTap: () => context.go('/incidents'),
                ),
                _ActionTile(
                  icon: Icons.chat_bubble_outline,
                  label: 'Team chat',
                  onTap: () => context.go('/chat'),
                ),
                _ActionTile(
                  icon: Icons.notifications_outlined,
                  label: 'Alerts',
                  badge: unread,
                  onTap: () => context.go('/notifications'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ActionTile extends StatelessWidget {
  const _ActionTile({
    required this.icon,
    required this.label,
    required this.onTap,
    this.badge,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final int? badge;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surfaceContainerHigh,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(16),
        side: BorderSide(color: context.ops.panelBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Badge(
                isLabelVisible: (badge ?? 0) > 0,
                label: Text('${badge ?? 0}'),
                child: Icon(icon, size: 30, color: theme.colorScheme.primary),
              ),
              const SizedBox(height: 8),
              Text(label, style: theme.textTheme.titleSmall),
            ],
          ),
        ),
      ),
    );
  }
}
