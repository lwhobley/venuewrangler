import 'shift.dart';

/// Timeline snap step and the shortest shift the editor will produce.
const int kSnapMinutes = 15;
const Duration kMinShift = Duration(minutes: 30);

/// The business day a timeline column covers: [startHour] on [date] for 24 hours, so an
/// evening shift that runs past midnight stays on one row.
DateTime businessDayStart(DateTime date, {int startHour = 6}) =>
    DateTime(date.year, date.month, date.day, startHour);

/// Which business day "now" falls in (before [startHour] still belongs to yesterday).
DateTime businessDateFor(DateTime now, {int startHour = 6}) {
  final d = DateTime(now.year, now.month, now.day);
  return now.hour < startHour ? d.subtract(const Duration(days: 1)) : d;
}

DateTime weekStart(DateTime date) {
  final d = DateTime(date.year, date.month, date.day);
  return d.subtract(Duration(days: d.weekday - DateTime.monday));
}

DateTime snapTime(DateTime t, {int minutes = kSnapMinutes}) {
  final total = t.hour * 60 + t.minute;
  final snapped = (total / minutes).round() * minutes;
  return DateTime(t.year, t.month, t.day).add(Duration(minutes: snapped));
}

Duration _deltaFor(double dx, double hourWidth) =>
    Duration(minutes: (dx / hourWidth * 60).round());

/// A shift dragged [dx] logical pixels sideways: same length, start snapped.
({DateTime start, DateTime end}) movedBy(
  DateTime start,
  DateTime end,
  double dx,
  double hourWidth,
) {
  final length = end.difference(start);
  final newStart = snapTime(start.add(_deltaFor(dx, hourWidth)));
  return (start: newStart, end: newStart.add(length));
}

/// The leading edge dragged [dx] pixels, never closer than [kMinShift] to the end.
({DateTime start, DateTime end}) resizedStartBy(
  DateTime start,
  DateTime end,
  double dx,
  double hourWidth,
) {
  var newStart = snapTime(start.add(_deltaFor(dx, hourWidth)));
  final latest = end.subtract(kMinShift);
  if (newStart.isAfter(latest)) newStart = latest;
  return (start: newStart, end: end);
}

/// The trailing edge dragged [dx] pixels, never closer than [kMinShift] to the start.
({DateTime start, DateTime end}) resizedEndBy(
  DateTime start,
  DateTime end,
  double dx,
  double hourWidth,
) {
  var newEnd = snapTime(end.add(_deltaFor(dx, hourWidth)));
  final earliest = start.add(kMinShift);
  if (newEnd.isBefore(earliest)) newEnd = earliest;
  return (start: start, end: newEnd);
}

bool shiftsOverlap(Shift a, Shift b) =>
    a.startTime.isBefore(b.endTime) && b.startTime.isBefore(a.endTime);

/// Ids of scheduled shifts that overlap another scheduled shift for the same person.
Set<String> conflictingShiftIds(Iterable<Shift> shifts) {
  final byStaff = <String, List<Shift>>{};
  for (final s in shifts) {
    if (s.staffId == null || s.status == ShiftStatus.cancelled) continue;
    byStaff.putIfAbsent(s.staffId!, () => []).add(s);
  }
  final ids = <String>{};
  for (final list in byStaff.values) {
    for (var i = 0; i < list.length; i++) {
      for (var j = i + 1; j < list.length; j++) {
        if (shiftsOverlap(list[i], list[j])) {
          ids
            ..add(list[i].id)
            ..add(list[j].id);
        }
      }
    }
  }
  return ids;
}

/// Hours [staffId] is scheduled within [from, to), clipping shifts that straddle the range.
double scheduledHours(
  Iterable<Shift> shifts,
  String staffId,
  DateTime from,
  DateTime to,
) {
  var minutes = 0;
  for (final s in shifts) {
    if (s.staffId != staffId || s.status == ShiftStatus.cancelled) continue;
    final a = s.startTime.isAfter(from) ? s.startTime : from;
    final b = s.endTime.isBefore(to) ? s.endTime : to;
    if (b.isAfter(a)) minutes += b.difference(a).inMinutes;
  }
  return minutes / 60;
}

String formatHours(double hours) {
  final whole = hours.truncate();
  final rest = ((hours - whole) * 60).round();
  return rest == 0 ? '${whole}h' : '${whole}h ${rest}m';
}

/// Greedy lane packing so overlapping shifts in one row are drawn stacked, not hidden.
Map<String, ({int lane, int lanes})> assignLanes(List<Shift> rowShifts) {
  final sorted = [...rowShifts]
    ..sort((a, b) => a.startTime.compareTo(b.startTime));
  final laneEnds = <DateTime>[];
  final laneOf = <String, int>{};
  for (final s in sorted) {
    var lane = laneEnds.indexWhere((end) => !end.isAfter(s.startTime));
    if (lane == -1) {
      laneEnds.add(s.endTime);
      lane = laneEnds.length - 1;
    } else {
      laneEnds[lane] = s.endTime;
    }
    laneOf[s.id] = lane;
  }
  final total = laneEnds.isEmpty ? 1 : laneEnds.length;
  return {for (final e in laneOf.entries) e.key: (lane: e.value, lanes: total)};
}

/// "6a", "12p", "1a" — compact hour labels for the timeline header.
String hourLabel(int hour24) {
  final h = hour24 % 24;
  final suffix = h < 12 ? 'a' : 'p';
  final h12 = h % 12 == 0 ? 12 : h % 12;
  return '$h12$suffix';
}

String clockLabel(DateTime t) {
  final h = t.hour % 12 == 0 ? 12 : t.hour % 12;
  final m = t.minute.toString().padLeft(2, '0');
  return t.minute == 0
      ? '$h${t.hour < 12 ? 'a' : 'p'}'
      : '$h:$m${t.hour < 12 ? 'a' : 'p'}';
}
