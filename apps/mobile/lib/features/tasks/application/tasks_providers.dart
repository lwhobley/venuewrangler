import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_providers.dart';
import '../../../core/offline/pending_mutation.dart';
import '../data/tasks_repository.dart';
import '../domain/operational_task.dart';

final tasksRepositoryProvider = Provider<TasksRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseTasksRepository(client);
});

final tasksForVenueProvider =
    FutureProvider.autoDispose.family<List<OperationalTask>, String>((ref, venueId) {
  return ref.watch(tasksRepositoryProvider).fetchTasksForVenue(venueId);
});

/// Mutation kind used for a task status change made while offline. Payload: `taskId`,
/// `status` (TaskStatus.toDb() string), `expectedUpdatedAt` (ISO 8601 — the task's
/// `updated_at` at the moment the change was made locally; see
/// TasksRepository.updateStatusIfUnchanged for why).
const String kTaskStatusUpdateMutationKind = 'task_status_update';

PendingMutation buildTaskStatusUpdateMutation({
  required OperationalTask task,
  required TaskStatus newStatus,
  String? userId,
}) {
  return PendingMutation(
    id: '${task.id}-${DateTime.now().microsecondsSinceEpoch}',
    kind: kTaskStatusUpdateMutationKind,
    createdAt: DateTime.now(),
    userId: userId,
    payload: {
      'taskId': task.id,
      'status': newStatus.toDb(),
      'expectedUpdatedAt': task.updatedAt.toIso8601String(),
    },
  );
}

/// Registered into the app-wide offline-queue handler map by app/bootstrap.dart (see
/// core/offline/offline_queue_providers.dart's offlineQueueHandlersProvider) so core/offline
/// never has to import this feature directly.
final taskMutationHandlersProvider = Provider<Map<String, MutationHandler>>((ref) {
  final repo = ref.watch(tasksRepositoryProvider);

  Future<MutationResult> handleStatusUpdate(Map<String, dynamic> payload) async {
    final taskId = payload['taskId'] as String;
    final status = TaskStatus.fromDb(payload['status'] as String);
    final expectedUpdatedAt = DateTime.parse(payload['expectedUpdatedAt'] as String);

    try {
      final applied = await repo.updateStatusIfUnchanged(taskId, status, expectedUpdatedAt);
      return applied
          ? const MutationResult(MutationOutcome.applied)
          : const MutationResult(
              MutationOutcome.conflict,
              message: 'This task was changed by someone else before your update synced.',
            );
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        return const MutationResult(
          MutationOutcome.conflict,
          message: "You no longer have permission to update this task.",
        );
      }
      rethrow; // network/5xx-shaped failures are retried by the queue controller.
    }
  }

  return {kTaskStatusUpdateMutationKind: handleStatusUpdate};
});
