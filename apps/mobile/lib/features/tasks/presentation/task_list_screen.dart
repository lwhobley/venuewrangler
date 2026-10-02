import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../venues/application/venues_providers.dart';
import '../application/tasks_providers.dart';
import '../domain/operational_task.dart';

/// Tasks scoped to the currently active venue (features/venues/application/venues_providers
/// .dart). A denied write (e.g. a staff member trying to create a task, which only
/// venue_manager+ may do per the `operational_tasks_insert_managers` RLS policy) is caught
/// here and shown as a message — the UI does not pre-check the user's role itself, since the
/// database is the actual authority and duplicating that check client-side would just be
/// another thing to keep in sync.
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

    return Scaffold(
      appBar: AppBar(title: Text('Tasks — ${venue.name}')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(tasksForVenueProvider(venue.id)),
        child: tasksAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _ErrorState(
            onRetry: () => ref.invalidate(tasksForVenueProvider(venue.id)),
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
              itemBuilder: (context, index) => _TaskTile(
                task: tasks[index],
                venueId: venue.id,
              ),
            );
          },
        ),
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
      await ref.read(tasksRepositoryProvider).createTask(venueId: venueId, title: title);
      ref.invalidate(tasksForVenueProvider(venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(_messageForPostgrestError(error))),
      );
    }
  }
}

class _TaskTile extends ConsumerWidget {
  const _TaskTile({required this.task, required this.venueId});

  final OperationalTask task;
  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return CheckboxListTile(
      value: task.isCompleted,
      title: Text(
        task.title,
        style: task.isCompleted
            ? const TextStyle(decoration: TextDecoration.lineThrough)
            : null,
      ),
      subtitle: task.description == null ? null : Text(task.description!),
      onChanged: (checked) async {
        final newStatus = (checked ?? false) ? TaskStatus.completed : TaskStatus.open;
        try {
          await ref.read(tasksRepositoryProvider).updateStatus(task.id, newStatus);
          ref.invalidate(tasksForVenueProvider(venueId));
        } on PostgrestException catch (error) {
          if (!context.mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(_messageForPostgrestError(error))),
          );
        }
      },
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
