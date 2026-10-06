import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/offline/offline_queue_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/status_chip.dart';
import '../../notifications/application/notifications_providers.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../schedules/domain/schedule_timeline.dart';
import '../../tasks/application/task_status_change.dart';
import '../../tasks/application/tasks_providers.dart';
import '../../tasks/domain/operational_task.dart';
import '../../time_clock/application/time_clock_providers.dart';
import '../../time_clock/domain/time_entry.dart';
import '../../venues/application/venues_providers.dart';
import '../domain/shift_mode.dart';

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
              loading: () => const _CardShell(
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => ErrorState(
                message: 'Could not load your shifts.',
                onRetry: () => ref.invalidate(shiftsForVenueProvider(venue.id)),
              ),
              data: (shifts) =>
                  _ShiftCard(mine: myShifts(shifts, userId, _now), now: _now),
            ),
            const SizedBox(height: 12),
            _ClockCard(entry: clockAsync, now: _now),
            const SizedBox(height: 20),
            _SectionTitle(
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
                  return const _CardShell(
                    child: EmptyState(
                      icon: Icons.task_alt,
                      message: "You're all caught up.",
                    ),
                  );
                }
                return Column(
                  children: [
                    for (final t in mine.take(6))
                      _TaskRow(
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
            const _SectionTitle('Quick actions'),
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

class _SectionTitle extends StatelessWidget {
  const _SectionTitle(this.text, {this.trailing});

  final String text;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: [
          Expanded(
            child: Text(text, style: Theme.of(context).textTheme.titleMedium),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

class _CardShell extends StatelessWidget {
  const _CardShell({required this.child}) : color = null;

  final Widget child;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: color ?? Theme.of(context).colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.ops.panelBorder),
      ),
      child: child,
    );
  }
}

class _ShiftCard extends StatelessWidget {
  const _ShiftCard({required this.mine, required this.now});

  final MyShifts mine;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = mine.current;
    final next = mine.next;

    if (current != null) {
      final left = current.endTime.difference(now);
      return _CardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const StatusChip(
              label: 'On shift',
              tone: Tone.success,
              icon: Icons.play_circle_outline,
            ),
            const SizedBox(height: 10),
            Text(
              current.roleLabel?.isNotEmpty == true
                  ? current.roleLabel!
                  : 'Your shift',
              style: theme.textTheme.headlineSmall,
            ),
            Text(
              '${clockLabel(current.startTime)} – ${clockLabel(current.endTime)}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                minHeight: 10,
                value: shiftProgress(current, now),
              ),
            ),
            const SizedBox(height: 8),
            Text('Ends in ${durationLabel(left)}'),
          ],
        ),
      );
    }

    if (next != null) {
      final until = next.startTime.difference(now);
      final today =
          next.startTime.day == now.day && next.startTime.month == now.month;
      return _CardShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const StatusChip(
              label: 'Next shift',
              tone: Tone.info,
              icon: Icons.schedule,
            ),
            const SizedBox(height: 10),
            Text(
              next.roleLabel?.isNotEmpty == true ? next.roleLabel! : 'Shift',
              style: theme.textTheme.headlineSmall,
            ),
            Text(
              '${today ? 'Today' : '${next.startTime.month}/${next.startTime.day}'}'
              ' · ${clockLabel(next.startTime)} – ${clockLabel(next.endTime)}',
              style: theme.textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text('Starts in ${durationLabel(until)}'),
          ],
        ),
      );
    }

    return const _CardShell(
      child: EmptyState(
        icon: Icons.event_available_outlined,
        message: 'No upcoming shifts scheduled.',
      ),
    );
  }
}

class _ClockCard extends StatelessWidget {
  const _ClockCard({required this.entry, required this.now});

  final AsyncValue<TimeEntry?> entry;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final active = entry.valueOrNull;
    final loading = entry.isLoading && active == null;

    final (Tone tone, String title, String detail, String action) =
        active == null
            ? (
                Tone.neutral,
                'Clocked out',
                'Clock in when you start your shift.',
                'Clock in',
              )
            : active.isOnBreak
                ? (
                    Tone.warning,
                    'On break',
                    'Break running ${durationLabel(active.activeBreak!.duration)}',
                    'End break',
                  )
                : (
                    Tone.success,
                    'Clocked in',
                    'Worked ${durationLabel(now.difference(active.clockInAt))}',
                    'Clock out',
                  );

    return _CardShell(
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (loading)
                  const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else ...[
                  StatusChip(
                    label: title,
                    tone: tone,
                    icon: Icons.timer_outlined,
                  ),
                  const SizedBox(height: 8),
                  Text(detail, style: theme.textTheme.bodyMedium),
                ],
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(
            style: FilledButton.styleFrom(minimumSize: const Size(120, 56)),
            onPressed: loading ? null : () => context.go('/time-clock'),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}

class _TaskRow extends StatelessWidget {
  const _TaskRow({
    required this.task,
    required this.now,
    required this.syncing,
    required this.onDone,
  });

  final OperationalTask task;
  final DateTime now;
  final bool syncing;
  final VoidCallback onDone;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final overdue = task.dueAt != null && task.dueAt!.isBefore(now);
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: theme.colorScheme.surfaceContainerLow,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: overdue ? context.ops.danger.fg : context.ops.panelBorder,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onDone,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 64),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              child: Row(
                children: [
                  Icon(
                    Icons.radio_button_unchecked,
                    size: 30,
                    color: theme.colorScheme.primary,
                    semanticLabel: 'Mark done',
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(task.title, style: theme.textTheme.titleSmall),
                        if (overdue || syncing)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Wrap(
                              spacing: 6,
                              children: [
                                if (overdue)
                                  const StatusChip(
                                    label: 'Overdue',
                                    tone: Tone.danger,
                                    dense: true,
                                  ),
                                if (syncing)
                                  const StatusChip(
                                    label: 'Syncing',
                                    tone: Tone.warning,
                                    icon: Icons.sync,
                                    dense: true,
                                  ),
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
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
