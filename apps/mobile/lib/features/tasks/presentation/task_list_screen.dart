import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/offline/offline_queue_providers.dart';
import '../../../core/offline/pending_mutation.dart';
import '../../venues/application/venues_providers.dart';
import '../application/tasks_providers.dart';
import '../domain/operational_task.dart';

/// Tasks scoped to the currently active venue (features/venues/application/venues_providers
/// .dart). A denied write (e.g. a staff member trying to create a task, which only
/// venue_manager+ may do per the `operational_tasks_insert_managers` RLS policy) is caught
/// here and shown as a message — the UI does not pre-check the user's role itself, since the
/// database is the actual authority and duplicating that check client-side would just be
/// another thing to keep in sync.
///
/// Status changes are offline-writable: see `_TaskTile` for the try-online-then-queue
/// fallback, and the conflict banner below for how a change that couldn't be reconciled on
/// reconnect (someone else changed the same task first) is surfaced rather than dropped or
/// silently overwritten.
class TaskListScreen extends ConsumerWidget {
  const TaskListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      // The router sends the user to /select-venue before they can reach this screen, but
      // guard anyway in case a widget test or future deep link renders this in isolation.
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final tasksAsync = ref.watch(tasksForVenueProvider(venue.id));
    final queueState = ref.watch(offlineQueueControllerProvider);
    final pendingStatusByTaskId = _pendingStatusByTaskId(queueState.pending);
    final taskConflicts = queueState.conflicts
        .where((mutation) => mutation.kind == kTaskStatusUpdateMutationKind)
        .toList(growable: false);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Tasks'),
        actions: [
          IconButton(
            icon: const Icon(Icons.view_kanban_outlined),
            tooltip: 'Task board',
            onPressed: () => context.go('/tasks/board'),
          ),
        ],
      ),
      body: Column(
        children: [
          for (final conflict in taskConflicts)
            _ConflictBanner(
              mutation: conflict,
              onDismiss: () {
                ref
                    .read(offlineQueueControllerProvider.notifier)
                    .dismissConflict(conflict.id);
                ref.invalidate(tasksForVenueProvider(venue.id));
              },
            ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: () async =>
                  ref.invalidate(tasksForVenueProvider(venue.id)),
              child: tasksAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (error, _) => _ErrorState(
                  onRetry: () =>
                      ref.invalidate(tasksForVenueProvider(venue.id)),
                ),
                data: (tasks) {
                  if (tasks.isEmpty) {
                    return LayoutBuilder(
                      builder: (context, constraints) => SingleChildScrollView(
                        physics: const AlwaysScrollableScrollPhysics(),
                        child: SizedBox(
                          height: constraints.maxHeight,
                          child: const Center(child: Text('No tasks yet.')),
                        ),
                      ),
                    );
                  }
                  return ListView.builder(
                    itemCount: tasks.length,
                    itemBuilder: (context, index) {
                      final task = tasks[index];
                      return _TaskTile(
                        task: task,
                        venueId: venue.id,
                        pendingStatus: pendingStatusByTaskId[task.id],
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _showCreateTaskDialog(context, ref, venue.id),
        child: const Icon(Icons.add),
      ),
    );
  }

  Future<void> _showCreateTaskDialog(
    BuildContext context,
    WidgetRef ref,
    String venueId,
  ) async {
    final controller = TextEditingController();
    final title = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('New task'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'Title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Create'),
          ),
        ],
      ),
    );

    if (title == null || title.isEmpty || !context.mounted) return;

    try {
      await ref
          .read(tasksRepositoryProvider)
          .createTask(venueId: venueId, title: title);
      ref.invalidate(tasksForVenueProvider(venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageForPostgrestError(error))),
      );
    }
  }
}

Map<String, TaskStatus> _pendingStatusByTaskId(List<PendingMutation> pending) {
  final result = <String, TaskStatus>{};
  for (final mutation in pending) {
    if (mutation.kind != kTaskStatusUpdateMutationKind) continue;
    final taskId = mutation.payload['taskId'] as String;
    result[taskId] = TaskStatus.fromDb(mutation.payload['status'] as String);
  }
  return result;
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({
    required this.task,
    required this.venueId,
    this.pendingStatus,
  });

  final OperationalTask task;
  final String venueId;

  /// Non-null when a status change for this task is still queued for sync — overrides the
  /// displayed checkbox state so the user sees their change immediately, without waiting for
  /// a server round-trip that may not happen until connectivity returns.
  final TaskStatus? pendingStatus;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final displayedStatus = pendingStatus ?? task.status;
    final isCompleted = displayedStatus == TaskStatus.completed;

    return CheckboxListTile(
      value: isCompleted,
      title: Text(
        task.title,
        style: isCompleted
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: Row(
        children: [
          if (task.description != null)
            Flexible(child: Text(task.description!)),
          if (pendingStatus != null) ...[
            if (task.description != null) const SizedBox(width: 8),
            const Icon(Icons.sync, size: 14),
            const SizedBox(width: 4),
            const Text(
              'Syncing…',
              style: TextStyle(fontStyle: FontStyle.italic),
            ),
          ],
        ],
      ),
      onChanged: (checked) => _onToggled(context, ref, checked ?? false),
    );
  }

  Future<void> _onToggled(
    BuildContext context,
    WidgetRef ref,
    bool checked,
  ) async {
    final messenger = ScaffoldMessenger.of(context);
    final newStatus = checked ? TaskStatus.completed : TaskStatus.open;

    try {
      await ref.read(tasksRepositoryProvider).updateStatus(task.id, newStatus);
      ref.invalidate(tasksForVenueProvider(venueId));
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        messenger.showSnackBar(
          SnackBar(content: Text(_messageForPostgrestError(error))),
        );
        return;
      }
      await _queueOffline(messenger, ref, newStatus);
    } catch (_) {
      // Anything else (no connectivity, a timeout, a transient 5xx) is treated as "try again
      // later" rather than shown as an error.
      await _queueOffline(messenger, ref, newStatus);
    }
  }

  Future<void> _queueOffline(
    ScaffoldMessengerState messenger,
    WidgetRef ref,
    TaskStatus newStatus,
  ) async {
    final mutation =
        buildTaskStatusUpdateMutation(task: task, newStatus: newStatus);
    await ref.read(offlineQueueControllerProvider.notifier).enqueue(mutation);

    messenger.showSnackBar(
      const SnackBar(
        content:
            Text("Saved offline — this will sync once you're back online."),
      ),
    );
  }
}

class _ConflictBanner extends StatelessWidget {
  const _ConflictBanner({required this.mutation, required this.onDismiss});

  final PendingMutation mutation;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return MaterialBanner(
      backgroundColor: Theme.of(context).colorScheme.errorContainer,
      content: const Text(
        "A task update you made offline couldn't be saved — it was changed by someone "
        'else first. Your change was not applied; please check the current status and '
        'redo it if still needed.',
      ),
      actions: [
        TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
      ],
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Could not load tasks.'),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

/// RLS/trigger denials surface as Postgres error code 42501 (insufficient_privilege); map
/// that to a message a non-technical user can act on rather than showing the raw Postgres
/// error text.
String _messageForPostgrestError(PostgrestException error) {
  if (error.code == '42501') {
    return "You don't have permission to do that.";
  }
  return 'Something went wrong. Please try again.';
}
