import 'operational_task.dart';

/// The three lanes of the board. Cancelled tasks aren't shown.
enum TaskLane {
  open('To do', TaskStatus.open),
  inProgress('In progress', TaskStatus.inProgress),
  completed('Done', TaskStatus.completed);

  const TaskLane(this.label, this.status);

  final String label;
  final TaskStatus status;

  static TaskLane? forStatus(TaskStatus status) {
    for (final lane in values) {
      if (lane.status == status) return lane;
    }
    return null;
  }
}

/// Status a task is displayed in: a change still waiting to sync wins over the stored one.
TaskStatus displayedStatus(
  OperationalTask task,
  Map<String, TaskStatus> pending,
) =>
    pending[task.id] ?? task.status;

/// Groups tasks into lanes. Within a lane, tasks with a due date come first (soonest first),
/// then the rest newest first.
Map<TaskLane, List<OperationalTask>> groupIntoLanes(
  Iterable<OperationalTask> tasks,
  Map<String, TaskStatus> pending,
) {
  final lanes = {for (final l in TaskLane.values) l: <OperationalTask>[]};
  for (final t in tasks) {
    final lane = TaskLane.forStatus(displayedStatus(t, pending));
    if (lane != null) lanes[lane]!.add(t);
  }
  for (final list in lanes.values) {
    list.sort((a, b) {
      final ad = a.dueAt;
      final bd = b.dueAt;
      if (ad != null && bd != null) return ad.compareTo(bd);
      if (ad != null) return -1;
      if (bd != null) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
  }
  return lanes;
}

bool isOverdue(OperationalTask task, TaskStatus shown, DateTime now) =>
    task.dueAt != null &&
    task.dueAt!.isBefore(now) &&
    shown != TaskStatus.completed &&
    shown != TaskStatus.cancelled;
