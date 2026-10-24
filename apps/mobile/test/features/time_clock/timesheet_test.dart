import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/time_entry.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/timesheet.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/timesheet_csv.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_clock.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/member_name.dart';

const chicago = VenueClock('America/Chicago');

TimesheetEntry entry(
  String id,
  String user,
  DateTime inAt,
  Duration length, {
  String? name,
  bool open = false,
  List<TimeBreak> breaks = const [],
  List<TimeCorrection> corrections = const [],
}) =>
    TimesheetEntry(
      id: id,
      userId: user,
      displayName: name,
      clockInAt: inAt,
      clockOutAt: open ? null : inAt.add(length),
      isOpen: open,
      breaks: breaks,
      clockInAttested: true,
      clockOutAttested: true,
      corrections: corrections,
    );

void main() {
  test('memberDisplayName prefers the resolved name and falls back once', () {
    expect(memberDisplayName('  Camila ', 'feda1234'), 'Camila');
    expect(memberDisplayName(null, 'feda1234'), 'Team member feda');
    expect(memberDisplayName('', 'ab'), 'Team member ab');
  });

  test('timesheet rows parse names, breaks and corrections', () {
    final e = TimesheetEntry.fromJson({
      'time_entry_id': 'e1',
      'user_id': 'u1',
      'display_name': 'Gemma Line',
      'clock_in_at': '2026-10-20T22:00:00Z',
      'clock_out_at': '2026-10-21T03:30:00Z',
      'is_open': false,
      'breaks': [
        {
          'type': 'unpaid',
          'start_at': '2026-10-21T00:00:00Z',
          'end_at': '2026-10-21T00:30:00Z',
        },
      ],
      'punch_source': 'attested',
      'clock_in_attested': true,
      'clock_out_attested': false,
      'location_anomaly': null,
      'corrections': [
        {
          'corrected_at': '2026-10-21T15:00:00Z',
          'corrected_by': 'm1',
          'corrected_by_name': 'Morgan',
          'reason': 'Forgot to clock out',
          'clock_out_before': null,
          'clock_out_after': '2026-10-21T03:30:00+00:00',
          'breaks_changed': false,
        },
      ],
    });
    expect(e.name, 'Gemma Line');
    expect(e.workedMinutes(), 300);
    expect(e.unpaidBreakMinutes(), 30);
    expect(e.isEdited, isTrue);
    expect(e.isUnverified, isTrue);
    expect(e.corrections.single.clockOutBefore, isNull);
    expect(e.corrections.single.byLabel, 'Morgan');
  });

  test('summarizeHours totals closed punches and splits weekly overtime', () {
    // Mon Oct 19 2026, 9:00 AM Chicago = 14:00 UTC. Five 9-hour days = 45 h.
    final monday = DateTime.utc(2026, 10, 19, 14);
    final entries = [
      for (var d = 0; d < 5; d++)
        entry(
          'e$d',
          'u1',
          monday.add(Duration(days: d)),
          const Duration(hours: 9),
          name: 'Colin',
        ),
      entry(
        'open',
        'u2',
        monday,
        Duration.zero,
        name: 'Ava',
        open: true,
      ),
    ];
    final summary = summarizeHours(entries, chicago, now: monday);
    expect(summary.people.map((p) => p.name), ['Ava', 'Colin']);
    final colin = summary.people[1];
    expect(colin.workedMinutes, 45 * 60);
    expect(colin.regularMinutes, 40 * 60);
    expect(colin.overtimeMinutes, 5 * 60);
    expect(summary.byEntry['e4'], (regular: 4 * 60, overtime: 5 * 60));
    final ava = summary.people[0];
    expect(ava.workedMinutes, 0, reason: 'open punches are not paid yet');
    expect(ava.openCount, 1);
    expect(summary.openCount, 1);
  });

  test('overtime resets each Monday in venue time', () {
    // Sunday Oct 25 11 PM Chicago is still the first week even though it is Monday in UTC.
    final sunday = DateTime.utc(2026, 10, 26, 4); // Sun 11 PM CDT
    final entries = [
      entry(
        'a',
        'u1',
        DateTime.utc(2026, 10, 19, 14),
        const Duration(hours: 40),
      ),
      entry('b', 'u1', sunday, const Duration(hours: 1)),
      entry(
        'c',
        'u1',
        DateTime.utc(2026, 10, 26, 14),
        const Duration(hours: 2),
      ),
    ];
    final s = summarizeHours(entries, chicago);
    expect(s.byEntry['b'], (regular: 0, overtime: 60));
    expect(s.byEntry['c'], (regular: 120, overtime: 0));
  });

  test('TimesheetRange.week is Monday-Sunday in the venue zone', () {
    final r = TimesheetRange.days(
      DateTime.utc(2026, 10, 19),
      DateTime.utc(2026, 10, 25),
      chicago,
    );
    expect(r.from, DateTime.utc(2026, 10, 19, 5));
    expect(r.to, DateTime.utc(2026, 10, 26, 5));
    expect(
      weekStartOf(DateTime.utc(2026, 10, 25, 23)),
      DateTime.utc(2026, 10, 19),
    );
  });

  test('entries CSV uses venue time, escapes fields and defuses formulas', () {
    final e = entry(
      'e1',
      'u1',
      DateTime.utc(2026, 10, 22, 6, 25), // 1:25 AM Chicago
      const Duration(hours: 8),
      name: '=HYPERLINK("x")',
      corrections: [
        TimeCorrection(
          correctedAt: DateTime.utc(2026, 10, 22, 20),
          correctedBy: 'm1',
          correctedByName: 'Morgan, Manager',
          reason: 'Forgot to clock out',
        ),
      ],
    );
    final summary = summarizeHours([e], chicago);
    final csv = timesheetEntriesCsv(
      summary: summary,
      clock: chicago,
      venueName: 'Fulton & Pine',
    );
    final lines = csv.trim().split('\r\n');
    expect(lines.first, startsWith('Venue,Employee,Employee ID,Date,Clock in'));
    expect(
      lines[1],
      'Fulton & Pine,"\'=HYPERLINK(""x"")",u1,2026-10-22,01:25,09:25,'
      'America/Chicago,0,0,8.00,8.00,0.00,Closed,Yes,Forgot to clock out,'
      '"Morgan, Manager"',
    );
  });

  test('summary CSV has one row per person for the period', () {
    final range = TimesheetRange.days(
      DateTime.utc(2026, 10, 19),
      DateTime.utc(2026, 10, 25),
      chicago,
    );
    final summary = summarizeHours(
      [
        entry(
          'a',
          'u1',
          DateTime.utc(2026, 10, 20, 14),
          const Duration(minutes: 465),
          name: 'Colin',
        ),
      ],
      chicago,
    );
    final lines = timesheetSummaryCsv(
      summary: summary,
      range: range,
      venueName: 'Fulton',
      timezoneId: chicago.timezoneId,
    ).trim().split('\r\n');
    expect(lines, hasLength(2));
    expect(
      lines[1],
      'Fulton,2026-10-19,2026-10-25,America/Chicago,Colin,u1,1,7.75,7.75,0.00,0,0',
    );
    expect(
      timesheetFileName('Fulton & Pine', range, 'hours'),
      'fulton-pine-hours-2026-10-19_to_2026-10-25.csv',
    );
  });
}
