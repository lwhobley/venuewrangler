/// Manager-facing views of punches: the live clock board and the hours (timesheet) review,
/// read from `public.venue_clock_board` / `public.venue_timesheet`
/// (supabase/migrations/20261022100000_venue_location_and_hours.sql). Neither carries GPS.
library;

import '../../venues/domain/venue_clock.dart';
import '../../workforce/domain/member_name.dart';
import 'time_entry.dart';

List<TimeBreak> _breaks(Object? raw) => (raw as List<dynamic>? ?? const [])
    .map((b) => TimeBreak.fromJson(Map<String, dynamic>.from(b as Map)))
    .toList(growable: false);

DateTime? _instant(Object? raw) =>
    raw is String && raw.isNotEmpty ? DateTime.parse(raw) : null;

/// Unpaid break minutes of [breaks] (an open break counts up to [now]).
int _unpaidMinutes(List<TimeBreak> breaks, DateTime now) {
  var total = 0;
  for (final b in breaks) {
    if (b.type != 'unpaid') continue;
    final end = b.endAt ?? now;
    if (end.isAfter(b.startAt)) total += end.difference(b.startAt).inMinutes;
  }
  return total;
}

/// One person on the clock right now.
class ClockBoardRow {
  const ClockBoardRow({
    required this.timeEntryId,
    required this.userId,
    this.displayName,
    required this.clockInAt,
    this.breaks = const [],
    this.clockInAttested = false,
    this.locationAnomaly,
  });

  final String timeEntryId;
  final String userId;
  final String? displayName;
  final DateTime clockInAt;
  final List<TimeBreak> breaks;
  final bool clockInAttested;
  final String? locationAnomaly;

  String get name => memberDisplayName(displayName, userId);

  TimeBreak? get activeBreak {
    for (final b in breaks) {
      if (b.isOpen) return b;
    }
    return null;
  }

  bool get isOnBreak => activeBreak != null;

  /// Time on the clock so far, less unpaid breaks.
  Duration workedSoFar([DateTime? now]) {
    final at = now ?? DateTime.now();
    final minutes =
        at.difference(clockInAt).inMinutes - _unpaidMinutes(breaks, at);
    return Duration(minutes: minutes < 0 ? 0 : minutes);
  }

  factory ClockBoardRow.fromJson(Map<String, dynamic> json) => ClockBoardRow(
        timeEntryId: json['time_entry_id'] as String,
        userId: json['user_id'] as String,
        displayName: json['display_name'] as String?,
        clockInAt: DateTime.parse(json['clock_in_at'] as String),
        breaks: _breaks(json['breaks']),
        clockInAttested: json['clock_in_attested'] as bool? ?? false,
        locationAnomaly: json['location_anomaly'] as String?,
      );
}

/// A manager's correction of a punch, from the audit log.
class TimeCorrection {
  const TimeCorrection({
    required this.correctedAt,
    this.correctedBy,
    this.correctedByName,
    this.reason,
    this.clockOutBefore,
    this.clockOutAfter,
    this.breaksChanged = false,
  });

  final DateTime correctedAt;
  final String? correctedBy;
  final String? correctedByName;
  final String? reason;

  /// Null before means the punch was still open (a missed clock-out).
  final DateTime? clockOutBefore;
  final DateTime? clockOutAfter;
  final bool breaksChanged;

  String get byLabel => correctedBy == null
      ? 'A former manager'
      : memberDisplayName(correctedByName, correctedBy!);

  factory TimeCorrection.fromJson(Map<String, dynamic> json) => TimeCorrection(
        correctedAt: DateTime.parse(json['corrected_at'] as String),
        correctedBy: json['corrected_by'] as String?,
        correctedByName: json['corrected_by_name'] as String?,
        reason: json['reason'] as String?,
        clockOutBefore: _instant(json['clock_out_before']),
        clockOutAfter: _instant(json['clock_out_after']),
        breaksChanged: json['breaks_changed'] as bool? ?? false,
      );
}

/// One punch in the hours review.
class TimesheetEntry {
  const TimesheetEntry({
    required this.id,
    required this.userId,
    this.displayName,
    required this.clockInAt,
    this.clockOutAt,
    required this.isOpen,
    this.breaks = const [],
    this.punchSource = 'direct',
    this.clockInAttested = false,
    this.clockOutAttested = false,
    this.locationAnomaly,
    this.corrections = const [],
  });

  final String id;
  final String userId;
  final String? displayName;
  final DateTime clockInAt;
  final DateTime? clockOutAt;
  final bool isOpen;
  final List<TimeBreak> breaks;
  final String punchSource;
  final bool clockInAttested;
  final bool clockOutAttested;
  final String? locationAnomaly;
  final List<TimeCorrection> corrections;

  String get name => memberDisplayName(displayName, userId);

  bool get isEdited => corrections.isNotEmpty;

  /// Unverified: the device did not prove a recorded end of the punch came from the app.
  bool get isUnverified => !clockInAttested || (!isOpen && !clockOutAttested);

  int unpaidBreakMinutes([DateTime? now]) =>
      _unpaidMinutes(breaks, now ?? DateTime.now());

  int paidBreakMinutes([DateTime? now]) {
    final at = now ?? DateTime.now();
    var total = 0;
    for (final b in breaks) {
      if (b.type == 'unpaid') continue;
      final end = b.endAt ?? at;
      if (end.isAfter(b.startAt)) total += end.difference(b.startAt).inMinutes;
    }
    return total;
  }

  /// Minutes worked: clock-in to clock-out (or [now] while open), less unpaid breaks. Paid
  /// breaks are working time.
  int workedMinutes([DateTime? now]) {
    final at = now ?? DateTime.now();
    final end = clockOutAt ?? at;
    final minutes =
        end.difference(clockInAt).inMinutes - unpaidBreakMinutes(at);
    return minutes < 0 ? 0 : minutes;
  }

  factory TimesheetEntry.fromJson(Map<String, dynamic> json) => TimesheetEntry(
        id: json['time_entry_id'] as String,
        userId: json['user_id'] as String,
        displayName: json['display_name'] as String?,
        clockInAt: DateTime.parse(json['clock_in_at'] as String),
        clockOutAt: _instant(json['clock_out_at']),
        isOpen: json['is_open'] as bool? ?? false,
        breaks: _breaks(json['breaks']),
        punchSource: json['punch_source'] as String? ?? 'direct',
        clockInAttested: json['clock_in_attested'] as bool? ?? false,
        clockOutAttested: json['clock_out_attested'] as bool? ?? false,
        locationAnomaly: json['location_anomaly'] as String?,
        corrections: (json['corrections'] as List<dynamic>? ?? const [])
            .map(
              (c) =>
                  TimeCorrection.fromJson(Map<String, dynamic>.from(c as Map)),
            )
            .toList(growable: false),
      );
}

/// Regular and overtime minutes of one closed punch.
typedef EntryHours = ({int regular, int overtime});

/// One person's totals for the range.
class PersonHours {
  const PersonHours({
    required this.userId,
    required this.name,
    required this.entries,
    required this.workedMinutes,
    required this.regularMinutes,
    required this.overtimeMinutes,
    required this.openCount,
    required this.editedCount,
  });

  final String userId;
  final String name;

  /// The person's punches in the range, earliest first.
  final List<TimesheetEntry> entries;

  /// Closed punches only: an open punch has no hours to pay yet.
  final int workedMinutes;
  final int regularMinutes;
  final int overtimeMinutes;
  final int openCount;
  final int editedCount;
}

class HoursSummary {
  const HoursSummary({required this.people, required this.byEntry});

  /// Sorted by name.
  final List<PersonHours> people;
  final Map<String, EntryHours> byEntry;

  int get totalMinutes => people.fold(0, (sum, p) => sum + p.workedMinutes);
  int get openCount => people.fold(0, (sum, p) => sum + p.openCount);
}

/// Weekly overtime threshold (US federal rule: hours over 40 in a workweek).
const kWeeklyOvertimeMinutes = 40 * 60;

/// The venue-local Monday (wall date) of the week [wall] falls in.
DateTime weekStartOf(DateTime wall) {
  final day = DateTime.utc(wall.year, wall.month, wall.day);
  return day.subtract(Duration(days: day.weekday - DateTime.monday));
}

/// Totals per person. Only closed punches count. Overtime is the time past
/// [weeklyOvertimeMinutes] within each Monday-Sunday venue-local week, taken in clock-in
/// order, so a range should cover whole weeks for overtime to be complete.
HoursSummary summarizeHours(
  List<TimesheetEntry> entries,
  VenueClock clock, {
  int weeklyOvertimeMinutes = kWeeklyOvertimeMinutes,
  DateTime? now,
}) {
  final byPerson = <String, List<TimesheetEntry>>{};
  for (final e in entries) {
    byPerson.putIfAbsent(e.userId, () => []).add(e);
  }
  final byEntry = <String, EntryHours>{};
  final people = <PersonHours>[];
  for (final MapEntry(key: userId, value: list) in byPerson.entries) {
    list.sort((a, b) => a.clockInAt.compareTo(b.clockInAt));
    final weekTotals = <DateTime, int>{};
    var worked = 0;
    var regular = 0;
    var overtime = 0;
    for (final e in list) {
      if (e.isOpen) continue;
      final minutes = e.workedMinutes(now);
      final week = weekStartOf(clock.wall(e.clockInAt));
      final before = weekTotals[week] ?? 0;
      final regularLeft = (weeklyOvertimeMinutes - before).clamp(0, minutes);
      final hours = (regular: regularLeft, overtime: minutes - regularLeft);
      weekTotals[week] = before + minutes;
      byEntry[e.id] = hours;
      worked += minutes;
      regular += hours.regular;
      overtime += hours.overtime;
    }
    people.add(
      PersonHours(
        userId: userId,
        name: list.first.name,
        entries: List.unmodifiable(list),
        workedMinutes: worked,
        regularMinutes: regular,
        overtimeMinutes: overtime,
        openCount: list.where((e) => e.isOpen).length,
        editedCount: list.where((e) => e.isEdited).length,
      ),
    );
  }
  people.sort((a, b) {
    final byName = a.name.toLowerCase().compareTo(b.name.toLowerCase());
    return byName != 0 ? byName : a.userId.compareTo(b.userId);
  });
  return HoursSummary(people: people, byEntry: byEntry);
}

/// "7:45" for 465 minutes.
String formatHoursMinutes(int minutes) =>
    '${minutes ~/ 60}:${(minutes % 60).toString().padLeft(2, '0')}';

/// "7.75" for 465 minutes (payroll systems take decimal hours).
String formatDecimalHours(int minutes) => (minutes / 60).toStringAsFixed(2);

/// A range of venue-local days: [startWall] to [endWall] inclusive (wall dates), with the
/// instants that bound it.
class TimesheetRange {
  TimesheetRange._(this.startWall, this.endWall, this.from, this.to);

  /// From venue-local midnight of [startWall] to venue-local midnight after [endWall].
  factory TimesheetRange.days(
    DateTime startWall,
    DateTime endWall,
    VenueClock clock,
  ) {
    final start = DateTime.utc(startWall.year, startWall.month, startWall.day);
    final end = DateTime.utc(endWall.year, endWall.month, endWall.day);
    return TimesheetRange._(
      start,
      end,
      clock.instant(start),
      clock.instant(end.add(const Duration(days: 1))),
    );
  }

  /// The Monday-Sunday venue week [weeksAgo] weeks before the current one.
  factory TimesheetRange.week(VenueClock clock, {int weeksAgo = 0}) {
    final monday =
        weekStartOf(clock.now).subtract(Duration(days: 7 * weeksAgo));
    return TimesheetRange.days(
      monday,
      monday.add(const Duration(days: 6)),
      clock,
    );
  }

  final DateTime startWall;
  final DateTime endWall;
  final DateTime from;
  final DateTime to;

  @override
  bool operator ==(Object other) =>
      other is TimesheetRange && other.from == from && other.to == to;

  @override
  int get hashCode => Object.hash(from, to);
}
