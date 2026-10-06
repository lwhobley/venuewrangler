import '../../floor/domain/floor_table.dart';
import '../../guests_reservations/domain/reservation.dart';
import '../../schedules/domain/schedule_timeline.dart';
import '../../tasks/domain/operational_task.dart';

/// The business day (6am–6am) containing [now], as a half-open [start, end) window.
({DateTime start, DateTime end}) businessDayWindow(DateTime now) {
  final start = businessDayStart(businessDateFor(now));
  return (start: start, end: start.add(const Duration(days: 1)));
}

bool _inWindow(DateTime t, ({DateTime start, DateTime end}) w) =>
    !t.isBefore(w.start) && t.isBefore(w.end);

/// Today's reservations assigned to [userId], earliest first, excluding cancelled/no-shows.
List<Reservation> myReservationsToday(
  Iterable<Reservation> reservations,
  String? userId,
  DateTime now,
) {
  if (userId == null) return const [];
  final w = businessDayWindow(now);
  final list = [
    for (final r in reservations)
      if (r.assignedTo == userId &&
          _inWindow(r.reservationTime, w) &&
          r.status != 'cancelled' &&
          r.status != 'no_show')
        r,
  ]..sort((a, b) => a.reservationTime.compareTo(b.reservationTime));
  return list;
}

/// Guests served today: party sizes of this person's reservations that were seated or
/// completed.
int coversToday(Iterable<Reservation> mine) => mine
    .where((r) => r.status == 'seated' || r.status == 'completed')
    .fold(0, (sum, r) => sum + r.partySize);

/// Tasks assigned to [userId] that are still open or in progress (a queued offline change
/// counts as already applied).
List<OperationalTask> myAssignedOpenTasks(
  Iterable<OperationalTask> tasks,
  String? userId,
  Map<String, TaskStatus> pending,
) {
  if (userId == null) return const [];
  final list = [
    for (final t in tasks)
      if (t.assignedTo == userId &&
          {TaskStatus.open, TaskStatus.inProgress}
              .contains(pending[t.id] ?? t.status))
        t,
  ]..sort((a, b) {
      final ad = a.dueAt;
      final bd = b.dueAt;
      if (ad != null && bd != null) return ad.compareTo(bd);
      if (ad != null) return -1;
      if (bd != null) return 1;
      return b.createdAt.compareTo(a.createdAt);
    });
  return list;
}

/// Tasks assigned to [userId] finished during today's business day.
int tasksDoneToday(
  Iterable<OperationalTask> tasks,
  String? userId,
  Map<String, TaskStatus> pending,
  DateTime now,
) {
  if (userId == null) return 0;
  final w = businessDayWindow(now);
  var n = 0;
  for (final t in tasks) {
    if (t.assignedTo != userId) continue;
    final queuedDone = pending[t.id] == TaskStatus.completed;
    final doneToday = t.status == TaskStatus.completed &&
        t.completedAt != null &&
        _inWindow(t.completedAt!.toLocal(), w);
    if (queuedDone || doneToday) n++;
  }
  return n;
}

/// Tables in [section] (case-insensitive), by label.
List<FloorTable> tablesInSection(Iterable<FloorTable> tables, String? section) {
  final key = section?.trim().toLowerCase();
  if (key == null || key.isEmpty) return const [];
  return [
    for (final t in tables)
      if (t.section.trim().toLowerCase() == key) t,
  ]..sort((a, b) => a.label.compareTo(b.label));
}
