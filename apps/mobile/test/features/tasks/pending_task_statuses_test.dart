import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/features/tasks/application/task_status_change.dart';
import 'package:venuewrangler_mobile/features/tasks/application/tasks_providers.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/operational_task.dart';

PendingMutation _statusChange(String id, String taskId, String? userId) =>
    PendingMutation(
      id: id,
      kind: kTaskStatusUpdateMutationKind,
      payload: {'taskId': taskId, 'status': 'completed'},
      createdAt: DateTime(2026),
      userId: userId,
    );

void main() {
  test('only the named user\'s queued status changes are reported', () {
    final queue = [
      _statusChange('1', 'task-a', 'user-a'),
      _statusChange('2', 'task-b', 'user-b'),
      _statusChange('3', 'task-legacy', null),
    ];

    expect(
      pendingTaskStatuses(queue, userId: 'user-b'),
      {'task-b': TaskStatus.completed},
    );
    expect(
      pendingTaskStatuses(queue, userId: 'user-a'),
      {'task-a': TaskStatus.completed},
    );
    expect(pendingTaskStatuses(queue, userId: 'user-c'), isEmpty);
  });
}
