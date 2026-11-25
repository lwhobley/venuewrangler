import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/transport_failure.dart';
import '../../../core/offline/offline_queue_providers.dart';
import '../../../core/offline/pending_mutation.dart';
import '../domain/operational_task.dart';
import 'tasks_providers.dart';

/// Status changes still queued for sync, by task id (latest wins). Conflicts are excluded: they
/// are no longer retried and are shown to the person separately. The offline queue is shared by
/// every account that signs in on a device, so only entries owned by [userId] count: another
/// user's unsynced change must not show up as this user's pending status.
Map<String, TaskStatus> pendingTaskStatuses(
  List<PendingMutation> pending, {
  required String? userId,
}) {
  final result = <String, TaskStatus>{};
  for (final m in pending) {
    if (m.userId != userId) continue;
    if (m.isConflict) continue;
    if (m.kind != kTaskStatusUpdateMutationKind) continue;
    result[m.payload['taskId'] as String] =
        TaskStatus.fromDb(m.payload['status'] as String);
  }
  return result;
}

/// Changes a task's status online; if the network is unavailable the change is queued and
/// synced later (with the same optimistic-concurrency check the list screen uses). A
/// permission denial is reported, not queued.
///
/// Takes the [ProviderContainer] (`ProviderScope.containerOf(context, listen: false)`) rather
/// than a `WidgetRef`: the refresh after the write must still happen if the calling widget was
/// disposed meanwhile, and a disposed widget's `ref` throws.
Future<void> changeTaskStatus(
  ProviderContainer container,
  ScaffoldMessengerState messenger,
  OperationalTask task,
  TaskStatus newStatus,
) async {
  try {
    await container
        .read(tasksRepositoryProvider)
        .updateStatus(task.id, newStatus);
    container.invalidate(tasksForVenueProvider(task.venueId));
  } catch (error) {
    if (error is PostgrestException && error.code == '42501') {
      messenger.showSnackBar(
        const SnackBar(content: Text("You don't have permission to do that.")),
      );
      return;
    }
    if (!isTransportFailure(error)) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("Couldn't update the task. Please try again."),
        ),
      );
      return;
    }
    await _queue(container, messenger, task, newStatus);
  }
}

Future<void> _queue(
  ProviderContainer container,
  ScaffoldMessengerState messenger,
  OperationalTask task,
  TaskStatus newStatus,
) async {
  await container
      .read(offlineQueueControllerProvider.notifier)
      .enqueue(buildTaskStatusUpdateMutation(task: task, newStatus: newStatus));
  messenger.showSnackBar(
    const SnackBar(
      content: Text("Saved offline — this will sync once you're back online."),
    ),
  );
}
