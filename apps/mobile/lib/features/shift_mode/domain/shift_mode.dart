import '../../schedules/domain/shift.dart';
import '../../tasks/domain/operational_task.dart';

/// The shift happening now and the next one after it, for one person.
class MyShifts {
  const MyShifts({this.current, this.next});

  final Shift? current;
  final Shift? next;
}

MyShifts myShifts(Iterable<Shift> shifts, String? userId, DateTime now) {
  if (userId == null) return const MyShifts();
  Shift? current;
  Shift? next;
  for (final s in shifts) {
    if (s.staffId != userId || s.status == ShiftStatus.cancelled) continue;
    if (!s.startTime.isAfter(now) && s.endTime.isAfter(now)) {
      if (current == null || s.startTime.isBefore(current.startTime)) {
        current = s;
      }
    } else if (s.startTime.isAfter(now)) {
      if (next == null || s.startTime.isBefore(next.startTime)) next = s;
    }
  }
  return MyShifts(current: current, next: next);
}

/// 0–1 of how far through [shift] [now] is.
double shiftProgress(Shift shift, DateTime now) {
  final total = shift.endTime.difference(shift.startTime).inSeconds;
  if (total <= 0) return 1;
  final done = now.difference(shift.startTime).inSeconds;
  return (done / total).clamp(0.0, 1.0);
}

/// "2h 10m", "45m", "now".
String durationLabel(Duration d) {
  if (d.inMinutes <= 0) return 'now';
  final h = d.inHours;
  final m = d.inMinutes % 60;
  if (h == 0) return '${m}m';
  return m == 0 ? '${h}h' : '${h}h ${m}m';
}

/// Tasks a person should see in shift mode: theirs and unassigned ones, unfinished, with
/// overdue first, then by due time, then newest. A queued status change counts as already
/// applied so a task they just ticked off disappears immediately.
List<OperationalTask> myOpenTasks(
  Iterable<OperationalTask> tasks,
  String? userId,
  Map<String, TaskStatus> pending,
  DateTime now,
) {
  final list = [
    for (final t in tasks)
      if ((t.assignedTo == null || t.assignedTo == userId) &&
          _unfinished(pending[t.id] ?? t.status))
        t,
  ];
  list.sort((a, b) {
    final aOver = a.dueAt != null && a.dueAt!.isBefore(now);
    final bOver = b.dueAt != null && b.dueAt!.isBefore(now);
    if (aOver != bOver) return aOver ? -1 : 1;
    final ad = a.dueAt;
    final bd = b.dueAt;
    if (ad != null && bd != null) return ad.compareTo(bd);
    if (ad != null) return -1;
    if (bd != null) return 1;
    return b.createdAt.compareTo(a.createdAt);
  });
  return list;
}

bool _unfinished(TaskStatus s) =>
    s == TaskStatus.open || s == TaskStatus.inProgress;
