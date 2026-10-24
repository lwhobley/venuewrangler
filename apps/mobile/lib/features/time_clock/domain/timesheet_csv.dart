/// Payroll CSV exports of the hours review. Times are the venue's wall clock (never the
/// device's), with the venue time zone in its own column.
library;

import '../../venues/domain/venue_clock.dart';
import 'timesheet.dart';

/// Quotes a CSV field when needed, and defuses spreadsheet formulas: a name such as
/// "=HYPERLINK(...)" is written as text, not evaluated, when the file is opened.
String csvField(String value) {
  var v = value;
  if (v.isNotEmpty && '=+-@\t\r'.contains(v[0])) v = "'$v";
  if (v.contains(RegExp('[",\r\n]'))) {
    v = '"${v.replaceAll('"', '""')}"';
  }
  return v;
}

String _row(List<String> fields) => fields.map(csvField).join(',');

String _date(DateTime wall) =>
    '${wall.year.toString().padLeft(4, '0')}-${wall.month.toString().padLeft(2, '0')}-${wall.day.toString().padLeft(2, '0')}';

String _time(DateTime wall) =>
    '${wall.hour.toString().padLeft(2, '0')}:${wall.minute.toString().padLeft(2, '0')}';

/// One row per punch, earliest first within each person.
String timesheetEntriesCsv({
  required HoursSummary summary,
  required VenueClock clock,
  required String venueName,
  DateTime? now,
}) {
  final lines = <String>[
    _row([
      'Venue',
      'Employee',
      'Employee ID',
      'Date',
      'Clock in',
      'Clock out',
      'Time zone',
      'Unpaid break (min)',
      'Paid break (min)',
      'Hours worked',
      'Regular hours',
      'Overtime hours',
      'Status',
      'Edited',
      'Edit reason',
      'Edited by',
    ]),
  ];
  for (final person in summary.people) {
    for (final e in person.entries) {
      final inWall = clock.wall(e.clockInAt);
      final outWall = e.clockOutAt == null ? null : clock.wall(e.clockOutAt!);
      final hours = summary.byEntry[e.id];
      final last = e.corrections.isEmpty ? null : e.corrections.last;
      lines.add(
        _row([
          venueName,
          person.name,
          e.userId,
          _date(inWall),
          _time(inWall),
          outWall == null
              ? ''
              : outWall.day == inWall.day &&
                      outWall.month == inWall.month &&
                      outWall.year == inWall.year
                  ? _time(outWall)
                  : '${_date(outWall)} ${_time(outWall)}',
          clock.timezoneId,
          '${e.unpaidBreakMinutes(now)}',
          '${e.paidBreakMinutes(now)}',
          e.isOpen ? '' : formatDecimalHours(e.workedMinutes(now)),
          hours == null ? '' : formatDecimalHours(hours.regular),
          hours == null ? '' : formatDecimalHours(hours.overtime),
          e.isOpen ? 'Open (missing clock-out)' : 'Closed',
          e.isEdited ? 'Yes' : 'No',
          last?.reason ?? '',
          last?.byLabel ?? '',
        ]),
      );
    }
  }
  return '${lines.join('\r\n')}\r\n';
}

/// One row per person: totals for the range.
String timesheetSummaryCsv({
  required HoursSummary summary,
  required TimesheetRange range,
  required String venueName,
  required String timezoneId,
}) {
  final lines = <String>[
    _row([
      'Venue',
      'Period start',
      'Period end',
      'Time zone',
      'Employee',
      'Employee ID',
      'Punches',
      'Hours worked',
      'Regular hours',
      'Overtime hours',
      'Open punches (not counted)',
      'Edited punches',
    ]),
  ];
  for (final p in summary.people) {
    lines.add(
      _row([
        venueName,
        _date(range.startWall),
        _date(range.endWall),
        timezoneId,
        p.name,
        p.userId,
        '${p.entries.length - p.openCount}',
        formatDecimalHours(p.workedMinutes),
        formatDecimalHours(p.regularMinutes),
        formatDecimalHours(p.overtimeMinutes),
        '${p.openCount}',
        '${p.editedCount}',
      ]),
    );
  }
  return '${lines.join('\r\n')}\r\n';
}

/// "marigold-hours-2026-10-19_to_2026-10-25.csv"
String timesheetFileName(String venueName, TimesheetRange range, String kind) {
  final slug = venueName
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9]+'), '-')
      .replaceAll(RegExp(r'^-+|-+$'), '');
  return '${slug.isEmpty ? 'venue' : slug}-$kind-${_date(range.startWall)}_to_${_date(range.endWall)}.csv';
}
