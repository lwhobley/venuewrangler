import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/offline/offline_queue_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/status_chip.dart';
import '../../floor/application/floor_providers.dart';
import '../../floor/domain/floor_table.dart';
import '../../floor/domain/table_status_style.dart';
import '../../guests_reservations/domain/reservation.dart';
import '../../notifications/application/notifications_providers.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../schedules/domain/schedule_timeline.dart';
import '../../shift_mode/domain/shift_mode.dart';
import '../../shift_mode/presentation/shift_widgets.dart';
import '../../tasks/application/task_status_change.dart';
import '../../tasks/application/tasks_providers.dart';
import '../../tasks/domain/operational_task.dart';
import '../../time_clock/application/time_clock_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../application/employee_providers.dart';
import '../domain/employee_day.dart';

/// Home for team members: their own shift, how it's going, their section, the reservations
/// and tasks assigned to them — nothing about anyone else.
class EmployeeHomeScreen extends ConsumerStatefulWidget {
  const EmployeeHomeScreen({super.key});

  @override
  ConsumerState<EmployeeHomeScreen> createState() => _EmployeeHomeScreenState();
}

class _EmployeeHomeScreenState extends ConsumerState<EmployeeHomeScreen> {
  late final Timer _ticker;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();
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
    ref.invalidate(todaysReservationsProvider);
    if (ref.read(myVenueRoleProvider).hasError) {
      ref.invalidate(myVenueRoleProvider);
    }
    await ref.read(shiftsForVenueProvider(venueId).future);
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }
    final theme = Theme.of(context);
    final userId = ref.watch(currentUserIdProvider);
    final shiftsAsync = ref.watch(shiftsForVenueProvider(venue.id));
    final tasksAsync = ref.watch(tasksForVenueProvider(venue.id));
    final clockAsync = ref.watch(activeTimeEntryProvider(venue.id));
    final reservationsAsync = ref.watch(todaysReservationsProvider);
    final tables = ref.watch(floorTablesStreamProvider).valueOrNull ??
        const <FloorTable>[];
    final section = ref.watch(mySectionProvider);
    final unread = ref.watch(unreadNotificationsCountProvider);
    final pending =
        pendingTaskStatuses(ref.watch(offlineQueueControllerProvider).pending);

    final myReservations = myReservationsToday(
      reservationsAsync.valueOrNull ?? const <Reservation>[],
      userId,
      _now,
    );
    final tasks = tasksAsync.valueOrNull ?? const <OperationalTask>[];
    final openTasks = myAssignedOpenTasks(tasks, userId, pending);
    final doneTasks = tasksDoneToday(tasks, userId, pending, _now);
    final sectionTables = tablesInSection(tables, section);
    final seated = sectionTables.where((t) => t.isSeated).length;
    final active = clockAsync.valueOrNull;

    final greeting = _now.hour < 12
        ? 'Good morning'
        : _now.hour < 17
            ? 'Good afternoon'
            : 'Good evening';

    return Scaffold(
      appBar: AppBar(
        title: Text(venue.name),
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
            tooltip: 'My profile',
            onPressed: () => context.push('/me'),
            icon: const Icon(Icons.account_circle_outlined),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => _refresh(venue.id),
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          children: [
            Text(greeting, style: theme.textTheme.headlineSmall),
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
            const SectionTitle('This shift'),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              mainAxisSpacing: 12,
              crossAxisSpacing: 12,
              childAspectRatio: 1.9,
              children: [
                _Kpi(
                  icon: Icons.timer_outlined,
                  label: 'On the clock',
                  value: active == null
                      ? '—'
                      : durationLabel(_now.difference(active.clockInAt)),
                ),
                _Kpi(
                  icon: Icons.groups_outlined,
                  label: 'Covers served',
                  value: '${coversToday(myReservations)}',
                ),
                _Kpi(
                  icon: Icons.task_alt,
                  label: 'Tasks done',
                  value: '$doneTasks of ${doneTasks + openTasks.length}',
                ),
                _Kpi(
                  icon: Icons.event_seat_outlined,
                  label: 'Section seated',
                  value: section == null
                      ? '—'
                      : '$seated of ${sectionTables.length}',
                ),
              ],
            ),
            const SizedBox(height: 20),
            SectionTitle(
              section == null ? 'My section' : 'My section · $section',
              trailing: TextButton(
                onPressed: () => context.go('/floor'),
                child: const Text('Open floor'),
              ),
            ),
            if (section == null)
              const CardShell(
                child: EmptyState(
                  icon: Icons.map_outlined,
                  message: 'No section assigned on your current shift.',
                ),
              )
            else if (sectionTables.isEmpty)
              CardShell(
                child: Text(
                  'No tables are set up in "$section" yet.',
                  style: theme.textTheme.bodyMedium,
                ),
              )
            else
              CardShell(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final t in sectionTables) _TableChip(table: t),
                  ],
                ),
              ),
            const SizedBox(height: 20),
            const SectionTitle('My reservations today'),
            if (reservationsAsync.isLoading && myReservations.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (myReservations.isEmpty)
              const CardShell(
                child: EmptyState(
                  icon: Icons.event_available_outlined,
                  message: 'No reservations assigned to you today.',
                ),
              )
            else
              for (final r in myReservations) _ReservationRow(reservation: r),
            const SizedBox(height: 20),
            const SectionTitle('My tasks'),
            if (tasksAsync.isLoading && tasks.isEmpty)
              const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              )
            else if (openTasks.isEmpty)
              const CardShell(
                child: EmptyState(
                  icon: Icons.task_alt,
                  message: 'No tasks assigned to you.',
                ),
              )
            else
              for (final t in openTasks)
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
          ],
        ),
      ),
    );
  }
}

class _Kpi extends StatelessWidget {
  const _Kpi({required this.icon, required this.label, required this.value});

  final IconData icon;
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.ops.panelBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: theme.colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          Text(
            value,
            style: theme.textTheme.titleLarge
                ?.copyWith(fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _TableChip extends StatelessWidget {
  const _TableChip({required this.table});

  final FloorTable table;

  @override
  Widget build(BuildContext context) {
    final style = TableStatusStyle.of(table.status);
    return StatusChip(
      label: '${table.label} · ${style.label}',
      tone: style.tone,
      icon: style.icon,
    );
  }
}

class _ReservationRow extends StatelessWidget {
  const _ReservationRow({required this.reservation});

  final Reservation reservation;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final r = reservation;
    final tone = switch (r.status) {
      'seated' => Tone.info,
      'completed' => Tone.neutral,
      'confirmed' => Tone.success,
      _ => Tone.warning,
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: CardShell(
        child: Row(
          children: [
            SizedBox(
              width: 64,
              child: Text(
                clockLabel(r.reservationTime),
                style: theme.textTheme.titleMedium
                    ?.copyWith(fontWeight: FontWeight.w800),
              ),
            ),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(r.guestName, style: theme.textTheme.titleSmall),
                  Text(
                    'Party of ${r.partySize}'
                    '${r.specialRequests?.isNotEmpty == true ? ' · ${r.specialRequests}' : ''}',
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall,
                  ),
                ],
              ),
            ),
            StatusChip(
              label: r.status[0].toUpperCase() + r.status.substring(1),
              tone: tone,
              dense: true,
            ),
          ],
        ),
      ),
    );
  }
}
