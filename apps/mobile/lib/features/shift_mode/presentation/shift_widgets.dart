import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/status_chip.dart';
import '../../schedules/domain/schedule_timeline.dart';
import '../../tasks/domain/operational_task.dart';
import '../../time_clock/domain/time_entry.dart';
import '../domain/shift_mode.dart';

// Building blocks shared by shift mode and the employee home screen.

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing});

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

class CardShell extends StatelessWidget {
  const CardShell({super.key, required this.child}) : color = null;

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

class ShiftCard extends StatelessWidget {
  const ShiftCard({super.key, required this.mine, required this.now});

  final MyShifts mine;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final current = mine.current;
    final next = mine.next;

    if (current != null) {
      final left = current.endTime.difference(now);
      return CardShell(
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
            if (current.section?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              StatusChip(
                label: 'Section: ${current.section}',
                tone: Tone.vip,
                icon: Icons.map_outlined,
                dense: true,
              ),
            ],
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
      return CardShell(
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
            if (next.section?.isNotEmpty == true) ...[
              const SizedBox(height: 8),
              StatusChip(
                label: 'Section: ${next.section}',
                tone: Tone.vip,
                icon: Icons.map_outlined,
                dense: true,
              ),
            ],
            const SizedBox(height: 8),
            Text('Starts in ${durationLabel(until)}'),
          ],
        ),
      );
    }

    return const CardShell(
      child: EmptyState(
        icon: Icons.event_available_outlined,
        message: 'No upcoming shifts scheduled.',
      ),
    );
  }
}

class ClockCard extends StatelessWidget {
  const ClockCard({super.key, required this.entry, required this.now});

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

    return CardShell(
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

class MyTaskRow extends StatelessWidget {
  const MyTaskRow({
    super.key,
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
