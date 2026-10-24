import 'dart:convert';

import '../../ai/domain/ai_models.dart';
import '../../staff_requests/domain/staff_request.dart';
import '../../venues/domain/venue_clock.dart';
import '../../workforce/domain/workforce_models.dart';
import 'schedule_timeline.dart';
import 'shift.dart';

/// "Draft a week" (`schedule_draft`). Everything the assistant is told is gathered here,
/// deterministically, and everything it answers with is re-checked here before a manager can
/// add it: unknown staff keys are dropped, times are parsed on the venue's clock, and each
/// proposed shift carries warnings computed from the real schedule (see [draftWarnings]).
/// Nothing in this file writes anything.

/// The Edge Function accepts at most 20,000 characters; stay under it.
const scheduleDraftMaxInputChars = 18000;
const scheduleDraftMaxRulesChars = 1500;
const scheduleDraftDefaultMaxHours = 40;

const _weekdayNames = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _two(int n) => n.toString().padLeft(2, '0');

/// `2026-10-26` for a wall date.
String wallDateKey(DateTime wall) =>
    '${wall.year}-${_two(wall.month)}-${_two(wall.day)}';

/// `2026-10-26T17:00` for a wall time, the format the assistant is asked to answer in.
String wallDateTimeKey(DateTime wall) =>
    '${wallDateKey(wall)}T${_two(wall.hour)}:${_two(wall.minute)}';

/// Monday 00:00 (wall time) of the week containing [wall].
DateTime weekStartFor(DateTime wall) {
  final day = DateTime.utc(wall.year, wall.month, wall.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

/// Wall time from an assistant answer. A value with an offset or `Z` is an instant and is
/// converted to the venue's clock; one without is taken to already be the venue's clock.
/// Null when it is not a date-time at all.
DateTime? parseDraftWall(String? raw, VenueClock clock) {
  final parsed = DateTime.tryParse((raw ?? '').trim());
  if (parsed == null) return null;
  if (parsed.isUtc) return clock.wall(parsed);
  return DateTime.utc(
    parsed.year,
    parsed.month,
    parsed.day,
    parsed.hour,
    parsed.minute,
  );
}

/// The roster as the assistant sees it: `staff_1`, `staff_2`, … instead of user ids, with a
/// shortened name ("Alice A.") so the manager's rules can mention people.
class DraftRoster {
  DraftRoster(Iterable<RosterMember> members)
      : _byKey = {
          for (final (i, m) in members.indexed) 'staff_${i + 1}': m,
        };

  final Map<String, RosterMember> _byKey;

  Iterable<MapEntry<String, RosterMember>> get entries => _byKey.entries;

  /// The person behind a key the assistant sent back; null when it is not a key we issued.
  RosterMember? resolve(String key) => _byKey[key.trim().toLowerCase()];

  String? keyFor(String userId) {
    for (final e in _byKey.entries) {
      if (e.value.userId == userId) return e.key;
    }
    return null;
  }

  /// "Alice Adams" becomes "Alice A."; a single name stays as it is.
  static String shortName(RosterMember m) {
    final parts = (m.displayName ?? '')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim()
        .split(' ')
        .where((p) => p.isNotEmpty)
        .toList();
    if (parts.isEmpty) return 'Team member';
    final first =
        parts.first.length > 20 ? parts.first.substring(0, 20) : parts.first;
    return parts.length == 1 ? first : '$first ${parts.last[0]}.';
  }
}

/// An approved time-off span for one person, as inclusive venue calendar dates.
class TimeOffSpan {
  const TimeOffSpan({
    required this.userId,
    required this.from,
    required this.to,
  });

  final String userId;
  final DateTime from;
  final DateTime to;

  bool overlapsRange(DateTime firstDay, DateTime lastDay) =>
      !to.isBefore(firstDay) && !from.isAfter(lastDay);
}

DateTime? _dateOnly(String? raw) {
  final parsed = DateTime.tryParse((raw ?? '').trim());
  if (parsed == null) return null;
  return DateTime.utc(parsed.year, parsed.month, parsed.day);
}

/// Approved time off and sick leave as date spans. Pending, denied and other request kinds are
/// ignored, as are rows with no usable date.
List<TimeOffSpan> approvedTimeOff(Iterable<StaffRequest> requests) {
  final spans = <TimeOffSpan>[];
  for (final r in requests) {
    if (r.status != StaffRequestStatus.approved) continue;
    if (r.kind != StaffRequestKind.timeOff &&
        r.kind != StaffRequestKind.sickLeave) {
      continue;
    }
    final from = _dateOnly(r.requestedRangeStart) ??
        _dateOnly(r.requestedForDate) ??
        _dateOnly(r.requestedRangeEnd);
    if (from == null) continue;
    var to = _dateOnly(r.requestedRangeEnd) ?? from;
    if (to.isBefore(from)) to = from;
    spans.add(TimeOffSpan(userId: r.userId, from: from, to: to));
  }
  return spans;
}

/// What was gathered for one request: the text to send and the key map to read the answer with.
class ScheduleDraftInput {
  const ScheduleDraftInput({
    required this.text,
    required this.roster,
    required this.existing,
    required this.timeOff,
    required this.weekStart,
    required this.maxHours,
    this.tooLarge = false,
  });

  final String text;
  final DraftRoster roster;

  /// The week's non-cancelled shifts, used again for the warnings.
  final List<Shift> existing;
  final List<TimeOffSpan> timeOff;
  final DateTime weekStart;
  final int maxHours;

  /// True when the data would not fit even after trimming; callers must not send [text].
  final bool tooLarge;
}

/// Gathers the compact JSON sent to the assistant. Data included: a short roster key, a
/// shortened name, access level, up to three usual role labels and hours already scheduled
/// that week for each person; the week's existing shifts (roster key, role, venue-local
/// times); approved time-off dates; the manager's rules. Never sent: user ids, emails, phone
/// numbers, pay rates.
ScheduleDraftInput buildScheduleDraftInput({
  required String rules,
  required Iterable<RosterMember> members,
  required Iterable<Shift> shifts,
  required Iterable<StaffRequest> requests,
  required VenueClock clock,
  required DateTime weekStartWall,
  required int maxHours,
  required DateTime todayWall,
}) {
  final roster = DraftRoster(members);
  final weekEndWall = weekStartWall.add(const Duration(days: 7));
  final weekStartUtc = clock.instant(weekStartWall);
  final weekEndUtc = clock.instant(weekEndWall);
  final all = shifts.toList();

  final existing = [
    for (final s in all)
      if (s.status != ShiftStatus.cancelled &&
          s.startTime.isBefore(weekEndUtc) &&
          s.endTime.isAfter(weekStartUtc))
        s,
  ]..sort((a, b) => a.startTime.compareTo(b.startTime));

  final spans = [
    for (final s in approvedTimeOff(requests))
      if (s.overlapsRange(
        weekStartWall,
        weekEndWall.subtract(const Duration(days: 1)),
      ))
        s,
  ];

  // Usual roles: the labels each person has most often worked, across the loaded schedule.
  final roleCounts = <String, Map<String, int>>{};
  for (final s in all) {
    final staff = s.staffId;
    final role = (s.roleLabel ?? '').trim();
    if (staff == null || role.isEmpty || s.status == ShiftStatus.cancelled) {
      continue;
    }
    final label = role.length > 40 ? role.substring(0, 40) : role;
    final counts = roleCounts.putIfAbsent(staff, () => {});
    counts[label] = (counts[label] ?? 0) + 1;
  }
  List<String> usualRoles(String userId) {
    final counts = roleCounts[userId];
    if (counts == null) return const [];
    final sorted = counts.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return [for (final e in sorted.take(3)) e.key];
  }

  double quarterHours(double h) => (h * 4).round() / 4;

  String? keyOf(String? userId) =>
      userId == null ? null : roster.keyFor(userId);

  Map<String, Object?> rosterRow(MapEntry<String, RosterMember> e) => {
        'key': e.key,
        'name': DraftRoster.shortName(e.value),
        'access': e.value.role,
        'usual_roles': usualRoles(e.value.userId),
        'hours_scheduled_this_week': quarterHours(
          scheduledHours(existing, e.value.userId, weekStartUtc, weekEndUtc),
        ),
      };

  Map<String, Object?> shiftRow(Shift s) => {
        'staff': keyOf(s.staffId),
        'role': s.roleLabel,
        'start': wallDateTimeKey(clock.wall(s.startTime)),
        'end': wallDateTimeKey(clock.wall(s.endTime)),
      };

  final trimmed = rules.trim();
  final trimmedRules = trimmed.length > scheduleDraftMaxRulesChars
      ? trimmed.substring(0, scheduleDraftMaxRulesChars)
      : trimmed;

  String encode(List<Shift> shiftRows) => jsonEncode({
        'manager_rules': trimmedRules,
        'timezone': clock.timezoneId,
        'today': wallDateKey(todayWall),
        'week': {
          'start': wallDateKey(weekStartWall),
          'end': wallDateKey(weekEndWall.subtract(const Duration(days: 1))),
          'days': [
            for (var i = 0; i < 7; i++)
              {
                'date': wallDateKey(weekStartWall.add(Duration(days: i))),
                'weekday': _weekdayNames[i],
              },
          ],
        },
        'max_hours_per_person': maxHours,
        'roster': [for (final e in roster.entries.take(80)) rosterRow(e)],
        'existing_shifts': [for (final s in shiftRows) shiftRow(s)],
        'approved_time_off': [
          for (final s in spans)
            if (keyOf(s.userId) != null)
              {
                'staff': keyOf(s.userId),
                'from': wallDateKey(s.from),
                'to': wallDateKey(s.to),
              },
        ],
      });

  var kept = existing;
  var text = encode(kept);
  while (text.length > scheduleDraftMaxInputChars && kept.isNotEmpty) {
    kept = kept.sublist(0, kept.length ~/ 2);
    text = encode(kept);
  }
  return ScheduleDraftInput(
    text: text,
    roster: roster,
    existing: existing,
    timeOff: spans,
    weekStart: weekStartWall,
    maxHours: maxHours,
    tooLarge: text.length > scheduleDraftMaxInputChars,
  );
}

/// One proposed shift, on the venue's wall clock, ready to review.
class DraftShift {
  const DraftShift({
    required this.id,
    required this.member,
    required this.roleLabel,
    required this.start,
    required this.end,
    this.reason = '',
  });

  /// Position in the review list; stable across edits.
  final int id;

  /// Null means an open (unassigned) shift.
  final RosterMember? member;
  final String roleLabel;
  final DateTime start;
  final DateTime end;
  final String reason;

  DraftShift copyWith({
    RosterMember? member,
    bool clearMember = false,
    String? roleLabel,
    DateTime? start,
    DateTime? end,
  }) =>
      DraftShift(
        id: id,
        member: clearMember ? null : (member ?? this.member),
        roleLabel: roleLabel ?? this.roleLabel,
        start: start ?? this.start,
        end: end ?? this.end,
        reason: reason,
      );
}

/// The reviewable proposals plus what was left out, so the screen can say so.
class DraftParseOutcome {
  const DraftParseOutcome({
    required this.shifts,
    required this.droppedUnknownStaff,
    required this.droppedBadTimes,
  });

  final List<DraftShift> shifts;
  final int droppedUnknownStaff;
  final int droppedBadTimes;
}

/// Turns the assistant's rows into [DraftShift]s. A row naming a staff key we never issued, or
/// without parsable times, is dropped; an empty key is an open shift.
DraftParseOutcome resolveDraftShifts(
  ScheduleDraftResult result,
  DraftRoster roster,
  VenueClock clock,
) {
  final shifts = <DraftShift>[];
  var unknown = 0;
  var bad = 0;
  for (final row in result.shifts) {
    final key = row.staffId.trim();
    RosterMember? member;
    if (key.isNotEmpty && key.toLowerCase() != 'null') {
      member = roster.resolve(key);
      if (member == null) {
        unknown++;
        continue;
      }
    }
    final start = parseDraftWall(row.startTime, clock);
    final end = parseDraftWall(row.endTime, clock);
    if (start == null || end == null) {
      bad++;
      continue;
    }
    shifts.add(
      DraftShift(
        id: shifts.length,
        member: member,
        roleLabel: row.roleLabel ?? '',
        start: start,
        end: end,
        reason: row.reason,
      ),
    );
  }
  return DraftParseOutcome(
    shifts: shifts,
    droppedUnknownStaff: unknown,
    droppedBadTimes: bad,
  );
}

enum DraftWarningKind {
  invalidTime,
  overlapsExisting,
  overlapsDraft,
  overHours,
  onTimeOff,
  inPast,
  outsideWeek,
  veryLong,
}

class DraftWarning {
  const DraftWarning(this.kind, this.message);

  final DraftWarningKind kind;
  final String message;

  /// A blocking problem cannot be added at all; the rest are advisory, as they are when a
  /// manager adds the same shift by hand.
  bool get blocking => kind == DraftWarningKind.invalidTime;
}

const draftLongShiftHours = 14;

/// Warnings for each proposed shift, keyed by [DraftShift.id], computed from the real schedule:
/// double-booking against [existing] and against the other *selected* proposals, the weekly
/// hours limit (existing hours in the week plus the selected proposals plus this one), approved
/// time off, past starts, and times outside the chosen week.
Map<int, List<DraftWarning>> draftWarnings({
  required List<DraftShift> drafts,
  required Set<int> selected,
  required Iterable<Shift> existing,
  required Iterable<TimeOffSpan> timeOff,
  required VenueClock clock,
  required DateTime weekStartWall,
  required int maxHours,
  required DateTime nowWall,
}) {
  final weekEndWall = weekStartWall.add(const Duration(days: 7));
  final weekStartUtc = clock.instant(weekStartWall);
  final weekEndUtc = clock.instant(weekEndWall);
  final live = [
    for (final s in existing)
      if (s.status != ShiftStatus.cancelled) s,
  ];

  double hoursInWeek(DateTime start, DateTime end) {
    final a = clock.instant(start);
    final b = clock.instant(end);
    final from = a.isAfter(weekStartUtc) ? a : weekStartUtc;
    final to = b.isBefore(weekEndUtc) ? b : weekEndUtc;
    return to.isAfter(from) ? to.difference(from).inMinutes / 60 : 0;
  }

  bool overlap(DraftShift a, DraftShift b) =>
      a.start.isBefore(b.end) && b.start.isBefore(a.end);

  final out = <int, List<DraftWarning>>{};
  for (final d in drafts) {
    final w = <DraftWarning>[];
    if (!d.end.isAfter(d.start)) {
      out[d.id] = [
        const DraftWarning(
          DraftWarningKind.invalidTime,
          'The end time must be after the start.',
        ),
      ];
      continue;
    }
    final member = d.member;
    final startUtc = clock.instant(d.start);
    final endUtc = clock.instant(d.end);

    if (d.start.isBefore(nowWall)) {
      w.add(
        const DraftWarning(
          DraftWarningKind.inPast,
          'This shift starts in the past.',
        ),
      );
    }
    if (d.start.isBefore(weekStartWall) || !d.start.isBefore(weekEndWall)) {
      w.add(
        const DraftWarning(
          DraftWarningKind.outsideWeek,
          'This shift is outside the week you picked.',
        ),
      );
    }
    if (d.end.difference(d.start).inMinutes > draftLongShiftHours * 60) {
      w.add(
        const DraftWarning(
          DraftWarningKind.veryLong,
          'This shift is longer than $draftLongShiftHours hours.',
        ),
      );
    }
    if (member != null) {
      final clash = live.any(
        (s) =>
            s.staffId == member.userId &&
            s.startTime.isBefore(endUtc) &&
            startUtc.isBefore(s.endTime),
      );
      if (clash) {
        w.add(
          const DraftWarning(
            DraftWarningKind.overlapsExisting,
            'Overlaps a shift this person already has.',
          ),
        );
      }
      final others = [
        for (final o in drafts)
          if (o.id != d.id &&
              selected.contains(o.id) &&
              o.member?.userId == member.userId &&
              o.end.isAfter(o.start))
            o,
      ];
      if (others.any((o) => overlap(o, d))) {
        w.add(
          const DraftWarning(
            DraftWarningKind.overlapsDraft,
            'Overlaps another proposed shift for this person.',
          ),
        );
      }
      final existingHours = scheduledHours(
        live,
        member.userId,
        weekStartUtc,
        weekEndUtc,
      );
      final total = existingHours +
          others.fold<double>(0, (n, o) => n + hoursInWeek(o.start, o.end)) +
          hoursInWeek(d.start, d.end);
      if (total > maxHours + 1e-9) {
        w.add(
          DraftWarning(
            DraftWarningKind.overHours,
            'Would bring this person to ${formatHours(total)} this week '
            '(limit ${maxHours}h).',
          ),
        );
      }
      final firstDay = DateTime.utc(d.start.year, d.start.month, d.start.day);
      final lastMoment = d.end.subtract(const Duration(minutes: 1));
      final lastDay =
          DateTime.utc(lastMoment.year, lastMoment.month, lastMoment.day);
      if (timeOff.any(
        (t) => t.userId == member.userId && t.overlapsRange(firstDay, lastDay),
      )) {
        w.add(
          const DraftWarning(
            DraftWarningKind.onTimeOff,
            'This person has approved time off on this day.',
          ),
        );
      }
    }
    if (w.isNotEmpty) out[d.id] = w;
  }
  return out;
}

/// "Fri Oct 30" for a wall date.
String draftDayLabel(DateTime wall) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${_weekdayNames[wall.weekday - 1]} ${months[wall.month - 1]} ${wall.day}';
}
