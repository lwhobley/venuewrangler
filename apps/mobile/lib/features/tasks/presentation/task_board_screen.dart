import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/offline/offline_queue_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/home_button.dart';
import '../../../core/widgets/state_views.dart';
import '../../../core/widgets/status_chip.dart';
import '../../venues/application/venues_providers.dart';
import '../../workforce/application/workforce_providers.dart';
import '../application/task_status_change.dart';
import '../application/tasks_providers.dart';
import '../domain/operational_task.dart';
import '../domain/task_board.dart';

const _months = [
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String _dueLabel(DateTime d) {
  final l = d.toLocal();
  final h = l.hour % 12 == 0 ? 12 : l.hour % 12;
  final m = l.minute.toString().padLeft(2, '0');
  return '${_months[l.month - 1]} ${l.day}, $h:$m ${l.hour < 12 ? 'AM' : 'PM'}';
}

/// Kanban view of the venue's tasks: To do / In progress / Done. Long-press a card and drag
/// it onto another lane to change its status; tap a card for details and a button-based way
/// to move it. Status changes use the same offline-aware path as the list view.
class TaskBoardScreen extends ConsumerStatefulWidget {
  const TaskBoardScreen({super.key});

  @override
  ConsumerState<TaskBoardScreen> createState() => _TaskBoardScreenState();
}

class _TaskBoardScreenState extends ConsumerState<TaskBoardScreen> {
  TaskLane _lane = TaskLane.open;
  Map<String, TaskStatus> _pending = const {};

  TaskStatus _statusOf(OperationalTask t) => displayedStatus(t, _pending);

  Future<void> _move(OperationalTask task, TaskStatus to) async {
    // Compare with what's on screen: a queued offline change may already have moved it.
    if (_statusOf(task) == to) return;
    await changeTaskStatus(ref, ScaffoldMessenger.of(context), task, to);
  }

  Future<void> _create(String venueId) async {
    final result = await showModalBottomSheet<_NewTask>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: const _NewTaskForm(),
      ),
    );
    if (result == null || !mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(tasksRepositoryProvider).createTask(
            venueId: venueId,
            title: result.title,
            description: result.description,
            dueAt: result.dueAt,
          );
      ref.invalidate(tasksForVenueProvider(venueId));
    } on PostgrestException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.code == '42501'
                ? "You don't have permission to create tasks."
                : 'Something went wrong. Please try again.',
          ),
        ),
      );
    }
  }

  Future<void> _details(
    OperationalTask task,
    TaskStatus shown,
    String? assignee,
  ) async {
    final action = await showModalBottomSheet<Object>(
      context: context,
      showDragHandle: true,
      builder: (context) => _TaskDetails(
        task: task,
        shown: shown,
        assignee: assignee,
      ),
    );
    if (action == null || !mounted) return;
    if (action is TaskStatus) {
      await _move(task, action);
    } else if (action == 'delete') {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await ref.read(tasksRepositoryProvider).deleteTask(task.id);
        ref.invalidate(tasksForVenueProvider(task.venueId));
      } on PostgrestException catch (e) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(
              e.code == '42501'
                  ? "You don't have permission to delete tasks."
                  : 'Something went wrong. Please try again.',
            ),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }
    final tasksAsync = ref.watch(tasksForVenueProvider(venue.id));
    final queue = ref.watch(offlineQueueControllerProvider);
    final pending = pendingTaskStatuses(queue.pending);
    _pending = pending;
    final roster = ref.watch(rosterForVenueProvider(venue.id)).valueOrNull;
    final names = {
      for (final m in roster ?? const [])
        m.userId: m.displayName ?? 'Team member',
    };

    return Scaffold(
      appBar: AppBar(
        leading: const HomeButton(),
        title: const Text('Task board'),
        actions: [
          IconButton(
            icon: const Icon(Icons.view_list_outlined),
            tooltip: 'List view',
            onPressed: () => context.go('/tasks'),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _create(venue.id),
        icon: const Icon(Icons.add),
        label: const Text('New task'),
      ),
      body: tasksAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ErrorState(
          message: 'Could not load tasks.',
          onRetry: () => ref.invalidate(tasksForVenueProvider(venue.id)),
        ),
        data: (tasks) {
          final lanes = groupIntoLanes(tasks, pending);
          return LayoutBuilder(
            builder: (context, constraints) {
              final wide = constraints.maxWidth >= 720;
              Widget card(OperationalTask t) {
                final shown = displayedStatus(t, pending);
                return _TaskCard(
                  task: t,
                  shown: shown,
                  syncing: pending.containsKey(t.id),
                  assignee: names[t.assignedTo],
                  onTap: () => _details(t, shown, names[t.assignedTo]),
                );
              }

              if (wide) {
                return Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final lane in TaskLane.values)
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 6),
                            child: _LaneColumn(
                              lane: lane,
                              statusOf: _statusOf,
                              tasks: lanes[lane]!,
                              cardBuilder: card,
                              onDrop: (t) => _move(t, lane.status),
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              }

              return Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
                    child: Row(
                      children: [
                        for (final lane in TaskLane.values)
                          Expanded(
                            child: Padding(
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 3),
                              child: _LaneTab(
                                lane: lane,
                                statusOf: _statusOf,
                                count: lanes[lane]!.length,
                                selected: lane == _lane,
                                onTap: () => setState(() => _lane = lane),
                                onDrop: (t) => _move(t, lane.status),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(
                      'Hold a card and drop it on a tab to move it.',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                    ),
                  ),
                  Expanded(
                    child: RefreshIndicator(
                      onRefresh: () async =>
                          ref.invalidate(tasksForVenueProvider(venue.id)),
                      child: lanes[_lane]!.isEmpty
                          ? ListView(
                              children: const [
                                SizedBox(height: 80),
                                EmptyState(
                                  icon: Icons.inbox_outlined,
                                  message: 'Nothing here.',
                                ),
                              ],
                            )
                          : ListView(
                              padding: const EdgeInsets.fromLTRB(12, 4, 12, 96),
                              children: [
                                for (final t in lanes[_lane]!) card(t),
                              ],
                            ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

class _LaneTab extends StatelessWidget {
  const _LaneTab({
    required this.lane,
    required this.statusOf,
    required this.count,
    required this.selected,
    required this.onTap,
    required this.onDrop,
  });

  final TaskLane lane;
  final TaskStatus Function(OperationalTask) statusOf;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<OperationalTask> onDrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<OperationalTask>(
      onWillAcceptWithDetails: (d) => statusOf(d.data) != lane.status,
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        return InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(12),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            padding: const EdgeInsets.symmetric(vertical: 10),
            decoration: BoxDecoration(
              color: hovering
                  ? theme.colorScheme.secondary.withValues(alpha: 0.25)
                  : selected
                      ? theme.colorScheme.primary.withValues(alpha: 0.15)
                      : theme.colorScheme.surfaceContainerHigh,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: hovering
                    ? theme.colorScheme.secondary
                    : selected
                        ? theme.colorScheme.primary
                        : context.ops.panelBorder,
                width: hovering || selected ? 2 : 1,
              ),
            ),
            child: Column(
              children: [
                Text(
                  '$count',
                  style: theme.textTheme.titleLarge
                      ?.copyWith(fontWeight: FontWeight.w800),
                ),
                Text(lane.label, style: theme.textTheme.labelMedium),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _LaneColumn extends StatelessWidget {
  const _LaneColumn({
    required this.lane,
    required this.statusOf,
    required this.tasks,
    required this.cardBuilder,
    required this.onDrop,
  });

  final TaskLane lane;
  final TaskStatus Function(OperationalTask) statusOf;
  final List<OperationalTask> tasks;
  final Widget Function(OperationalTask) cardBuilder;
  final ValueChanged<OperationalTask> onDrop;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return DragTarget<OperationalTask>(
      onWillAcceptWithDetails: (d) => statusOf(d.data) != lane.status,
      onAcceptWithDetails: (d) => onDrop(d.data),
      builder: (context, candidates, _) {
        final hovering = candidates.isNotEmpty;
        return Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: hovering
                  ? theme.colorScheme.secondary
                  : context.ops.panelBorder,
              width: hovering ? 2 : 1,
            ),
          ),
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 2, 4, 10),
                child: Text(
                  '${lane.label}  ·  ${tasks.length}',
                  style: theme.textTheme.titleSmall,
                ),
              ),
              Expanded(
                child: tasks.isEmpty
                    ? const EmptyState(
                        icon: Icons.inbox_outlined,
                        message: 'Nothing here.',
                      )
                    : ListView(
                        children: [for (final t in tasks) cardBuilder(t)],
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.shown,
    required this.syncing,
    required this.assignee,
    required this.onTap,
  });

  final OperationalTask task;
  final TaskStatus shown;
  final bool syncing;
  final String? assignee;
  final VoidCallback onTap;

  Widget _body(BuildContext context, {bool dragging = false}) {
    final theme = Theme.of(context);
    final overdue = isOverdue(task, shown, DateTime.now());
    final done = shown == TaskStatus.completed;
    return Card(
      margin: const EdgeInsets.only(bottom: 10),
      elevation: dragging ? 8 : 0,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: dragging ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                task.title,
                style: theme.textTheme.titleSmall?.copyWith(
                  decoration: done ? TextDecoration.lineThrough : null,
                ),
              ),
              if (task.description != null && task.description!.isNotEmpty) ...[
                const SizedBox(height: 4),
                Text(
                  task.description!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall,
                ),
              ],
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (task.dueAt != null)
                    StatusChip(
                      label: overdue
                          ? 'Overdue ${_dueLabel(task.dueAt!)}'
                          : 'Due ${_dueLabel(task.dueAt!)}',
                      tone: overdue ? Tone.danger : Tone.neutral,
                      icon: Icons.schedule,
                      dense: true,
                    ),
                  if (assignee != null)
                    StatusChip(
                      label: assignee!,
                      tone: Tone.info,
                      icon: Icons.person_outline,
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
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return LongPressDraggable<OperationalTask>(
      data: task,
      onDragStarted: HapticFeedback.mediumImpact,
      feedback: SizedBox(
        width: 280,
        child: Material(
          color: Colors.transparent,
          child: _body(context, dragging: true),
        ),
      ),
      childWhenDragging: Opacity(opacity: 0.3, child: _body(context)),
      child: Semantics(
        label: '${task.title}, ${shown.name}. Tap for options.',
        child: _body(context),
      ),
    );
  }
}

class _TaskDetails extends StatelessWidget {
  const _TaskDetails({
    required this.task,
    required this.shown,
    required this.assignee,
  });

  final OperationalTask task;
  final TaskStatus shown;
  final String? assignee;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(task.title, style: theme.textTheme.titleLarge),
            if (task.description != null && task.description!.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(task.description!),
            ],
            const SizedBox(height: 8),
            if (task.dueAt != null) Text('Due ${_dueLabel(task.dueAt!)}'),
            if (assignee != null) Text('Assigned to $assignee'),
            const SizedBox(height: 16),
            Text('Move to', style: theme.textTheme.labelMedium),
            const SizedBox(height: 8),
            SegmentedButton<TaskStatus>(
              showSelectedIcon: false,
              segments: [
                for (final lane in TaskLane.values)
                  ButtonSegment(value: lane.status, label: Text(lane.label)),
              ],
              selected: {
                if (TaskLane.forStatus(shown) != null) shown,
              },
              emptySelectionAllowed: true,
              onSelectionChanged: (s) {
                if (s.isNotEmpty) Navigator.pop(context, s.first);
              },
            ),
            const SizedBox(height: 12),
            TextButton.icon(
              onPressed: () => Navigator.pop(context, 'delete'),
              icon: Icon(Icons.delete_outline, color: context.ops.danger.fg),
              label: Text(
                'Delete task',
                style: TextStyle(color: context.ops.danger.fg),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _NewTask {
  const _NewTask(this.title, this.description, this.dueAt);

  final String title;
  final String? description;
  final DateTime? dueAt;
}

class _NewTaskForm extends StatefulWidget {
  const _NewTaskForm();

  @override
  State<_NewTaskForm> createState() => _NewTaskFormState();
}

class _NewTaskFormState extends State<_NewTaskForm> {
  final _title = TextEditingController();
  final _description = TextEditingController();
  DateTime? _due;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _pickDue() async {
    final now = DateTime.now();
    final date = await showDatePicker(
      context: context,
      initialDate: _due ?? now,
      firstDate: now.subtract(const Duration(days: 1)),
      lastDate: now.add(const Duration(days: 365)),
    );
    if (date == null || !mounted) return;
    final time = await showTimePicker(
      context: context,
      initialTime: TimeOfDay.fromDateTime(_due ?? now),
    );
    if (time == null) return;
    setState(
      () => _due =
          DateTime(date.year, date.month, date.day, time.hour, time.minute),
    );
  }

  void _submit() {
    final title = _title.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Give the task a title');
      return;
    }
    Navigator.pop(
      context,
      _NewTask(title, _description.text.trim(), _due),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('New task', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _title,
              autofocus: true,
              decoration:
                  InputDecoration(labelText: 'Title', errorText: _error),
              onChanged: (_) {
                if (_error != null) setState(() => _error = null);
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _description,
              maxLines: 3,
              decoration: const InputDecoration(
                labelText: 'Details (optional)',
              ),
            ),
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Due'),
              subtitle: Text(_due == null ? 'No due date' : _dueLabel(_due!)),
              trailing: _due == null
                  ? const Icon(Icons.edit_calendar_outlined)
                  : IconButton(
                      icon: const Icon(Icons.clear),
                      tooltip: 'Clear due date',
                      onPressed: () => setState(() => _due = null),
                    ),
              onTap: _pickDue,
            ),
            const SizedBox(height: 12),
            FilledButton(onPressed: _submit, child: const Text('Create')),
          ],
        ),
      ),
    );
  }
}
