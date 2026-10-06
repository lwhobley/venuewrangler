import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/offline/offline_queue_providers.dart';
import '../../../core/offline/pending_mutation.dart';
import '../domain/operational_task.dart';
import 'tasks_providers.dart';

/// Status changes still queued for sync, by task id (latest wins).
Map<String, TaskStatus> pendingTaskStatuses(List<PendingMutation> pending) {
  final result = <String, TaskStatus>{};
  for (final m in pending) {
    if (m.kind != kTaskStatusUpdateMutationKind) continue;
    result[m.payload['taskId'] as String] =
        TaskStatus.fromDb(m.payload['status'] as String);
  }
  return result;
}

/// Changes a task's status online; if the network is unavailable the change is queued and
/// synced later (with the same optimistic-concurrency check the list screen uses). A
/// permission denial is reported, not queued.
Future<void> changeTaskStatus(
  WidgetRef ref,
  ScaffoldMessengerState messenger,
  OperationalTask task,
  TaskStatus newStatus,
) async {
  try {
    await ref.read(tasksRepositoryProvider).updateStatus(task.id, newStatus);
    ref.invalidate(tasksForVenueProvider(task.venueId));
  } on PostgrestException catch (error) {
    if (error.code == '42501') {
      messenger.showSnackBar(
        const SnackBar(content: Text("You don't have permission to do that.")),
      );
      return;
    }
    await _queue(ref, messenger, task, newStatus);
  } catch (_) {
    await _queue(ref, messenger, task, newStatus);
  }
}

Future<void> _queue(
  WidgetRef ref,
  ScaffoldMessengerState messenger,
  OperationalTask task,
  TaskStatus newStatus,
) async {
  await ref
      .read(offlineQueueControllerProvider.notifier)
      .enqueue(buildTaskStatusUpdateMutation(task: task, newStatus: newStatus));
  messenger.showSnackBar(
    const SnackBar(
      content: Text("Saved offline — this will sync once you're back online."),
    ),
  );
}
