import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/operational_task.dart';

/// As with the other Phase 2 repositories, authorization is enforced entirely by Postgres
/// RLS and the `enforce_task_update_scope`/`prepare_task_insert` triggers (see
/// supabase/migrations/20261002010000_tasks_schema.sql) — this class does not re-check role
/// or ownership itself, because a modified client could not bypass the database layer
/// anyway. A denied write surfaces as a `PostgrestException`; callers should catch it and
/// show the user why (see TaskListScreen).
abstract interface class TasksRepository {
  Future<List<OperationalTask>> fetchTasksForVenue(String venueId);

  Future<void> createTask({
    required String venueId,
    required String title,
    String? description,
    DateTime? dueAt,
    String? assignedTo,
  });

  Future<void> updateStatus(String taskId, TaskStatus status);

  /// Like [updateStatus], but only applies when the row's `updated_at` still equals
  /// [expectedUpdatedAt] — an optimistic-concurrency check. Returns `false` (no exception)
  /// when the row changed in the meantime or no longer exists, so the caller can treat that
  /// as a conflict rather than assume the write succeeded. Used by the offline queue handler
  /// (see features/tasks/application/tasks_providers.dart) for mutations that were queued
  /// while offline and may now be stale.
  Future<bool> updateStatusIfUnchanged(
    String taskId,
    TaskStatus status,
    DateTime expectedUpdatedAt,
  );

  Future<void> deleteTask(String taskId);
}

class SupabaseTasksRepository implements TasksRepository {
  const SupabaseTasksRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<OperationalTask>> fetchTasksForVenue(String venueId) async {
    final rows = await _client
        .from('operational_tasks')
        .select()
        .eq('venue_id', venueId)
        .order('created_at', ascending: false);

    return rows.map(OperationalTask.fromJson).toList(growable: false);
  }

  @override
  Future<void> createTask({
    required String venueId,
    required String title,
    String? description,
    DateTime? dueAt,
    String? assignedTo,
  }) async {
    await _client.from('operational_tasks').insert({
      'venue_id': venueId,
      'title': title,
      if (description != null && description.isNotEmpty)
        'description': description,
      if (dueAt != null) 'due_at': dueAt.toUtc().toIso8601String(),
      if (assignedTo != null) 'assigned_to': assignedTo,
    });
  }

  @override
  Future<void> updateStatus(String taskId, TaskStatus status) async {
    await _client
        .from('operational_tasks')
        .update({'status': status.toDb()}).eq('id', taskId);
  }

  @override
  Future<bool> updateStatusIfUnchanged(
    String taskId,
    TaskStatus status,
    DateTime expectedUpdatedAt,
  ) async {
    final rows = await _client
        .from('operational_tasks')
        .update({'status': status.toDb()})
        .eq('id', taskId)
        .eq('updated_at', expectedUpdatedAt.toIso8601String())
        .select();

    return rows.isNotEmpty;
  }

  @override
  Future<void> deleteTask(String taskId) async {
    await _client.from('operational_tasks').delete().eq('id', taskId);
  }
}
