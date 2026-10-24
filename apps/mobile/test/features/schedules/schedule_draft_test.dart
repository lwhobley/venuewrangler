import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/schedules/application/schedules_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/data/schedules_repository.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/schedule_draft.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/schedules/presentation/schedule_draft_screen.dart';
import 'package:venuewrangler_mobile/features/staff_requests/application/staff_requests_providers.dart';
import 'package:venuewrangler_mobile/features/staff_requests/domain/staff_request.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_clock.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

const _alice = RosterMember(
  userId: 'alice-id',
  role: 'staff',
  displayName: 'Alice Adams',
);
const _bob = RosterMember(
  userId: 'bob-id',
  role: 'staff',
  displayName: 'Bob Brown',
);
const _clock = VenueClock('America/Chicago');

/// Monday 00:00 venue time of the week the screen opens on (next week).
DateTime _defaultWeek() =>
    weekStartFor(_clock.now).add(const Duration(days: 7));

Shift _shift(
  String id,
  String staff,
  DateTime startWall,
  DateTime endWall, {
  String role = 'Server',
  ShiftStatus status = ShiftStatus.scheduled,
}) =>
    Shift(
      id: id,
      venueId: 'venue-1',
      staffId: staff,
      roleLabel: role,
      startTime: _clock.instant(startWall),
      endTime: _clock.instant(endWall),
      status: status,
    );

StaffRequest _request(
  String user,
  String from,
  String to, {
  StaffRequestStatus status = StaffRequestStatus.approved,
  StaffRequestKind kind = StaffRequestKind.timeOff,
}) =>
    StaffRequest(
      id: 'r-$user-$from-${status.name}',
      venueId: 'venue-1',
      organizationId: 'org',
      userId: user,
      kind: kind,
      status: status,
      title: 'Off',
      requestedRangeStart: from,
      requestedRangeEnd: to,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

DateTime _at(DateTime week, int day, int hour) =>
    DateTime.utc(week.year, week.month, week.day + day, hour);

void main() {
  group('gatherer', () {
    final week = DateTime.utc(2026, 10, 26);

    ScheduleDraftInput build({
      List<Shift> shifts = const [],
      List<StaffRequest> requests = const [],
      String rules = 'Two servers Friday night',
    }) =>
        buildScheduleDraftInput(
          rules: rules,
          members: const [_alice, _bob],
          shifts: shifts,
          requests: requests,
          clock: _clock,
          weekStartWall: week,
          maxHours: 40,
          todayWall: DateTime.utc(2026, 10, 24, 12),
        );

    test('sends short keys, usual roles, week shifts and hours so far', () {
      final input = build(
        shifts: [
          _shift('a', 'alice-id', _at(week, 1, 17), _at(week, 1, 23)),
          _shift('b', 'alice-id', _at(week, 3, 17), _at(week, 3, 21)),
          // Outside the week, and a cancelled one: neither counts.
          _shift('c', 'alice-id', _at(week, 9, 17), _at(week, 9, 23)),
          _shift(
            'd',
            'bob-id',
            _at(week, 2, 17),
            _at(week, 2, 23),
            status: ShiftStatus.cancelled,
          ),
        ],
      );
      final json = jsonDecode(input.text) as Map<String, dynamic>;
      final roster = (json['roster'] as List).cast<Map<String, dynamic>>();
      expect(roster.map((r) => r['key']), ['staff_1', 'staff_2']);
      expect(roster.first['name'], 'Alice A.');
      expect(roster.first['hours_scheduled_this_week'], 10);
      expect(roster.first['usual_roles'], ['Server']);
      expect(roster.last['hours_scheduled_this_week'], 0);
      final shifts =
          (json['existing_shifts'] as List).cast<Map<String, dynamic>>();
      expect(shifts.map((s) => s['start']), [
        '2026-10-27T17:00',
        '2026-10-29T17:00',
      ]);
      expect(shifts.first['staff'], 'staff_1');
      expect((json['week'] as Map)['start'], '2026-10-26');
      expect((json['week'] as Map)['end'], '2026-11-01');
      expect(json['max_hours_per_person'], 40);
      expect(json['manager_rules'], 'Two servers Friday night');
    });

    test('never sends user ids, full names or contact details', () {
      final input = build(
        shifts: [_shift('a', 'alice-id', _at(week, 1, 17), _at(week, 1, 23))],
        requests: [_request('bob-id', '2026-10-30', '2026-10-30')],
      );
      expect(input.text, isNot(contains('alice-id')));
      expect(input.text, isNot(contains('bob-id')));
      expect(input.text, isNot(contains('Adams')));
      expect(input.text, isNot(contains('@')));
    });

    test('only approved time off in the week is sent', () {
      final input = build(
        requests: [
          _request('alice-id', '2026-10-30', '2026-10-31'),
          _request(
            'bob-id',
            '2026-10-30',
            '2026-10-30',
            status: StaffRequestStatus.pending,
          ),
          _request('bob-id', '2026-12-01', '2026-12-02'),
          _request(
            'bob-id',
            '2026-10-28',
            '2026-10-28',
            kind: StaffRequestKind.other,
          ),
        ],
      );
      final json = jsonDecode(input.text) as Map<String, dynamic>;
      expect(json['approved_time_off'], [
        {'staff': 'staff_1', 'from': '2026-10-30', 'to': '2026-10-31'},
      ]);
      expect(input.timeOff, hasLength(1));
    });

    test('the rules are carried as data and capped', () {
      final input = build(rules: 'x' * 5000);
      final json = jsonDecode(input.text) as Map<String, dynamic>;
      expect((json['manager_rules'] as String).length, 1500);
    });

    test('trims existing shifts to fit and flags an unfittable request', () {
      final many = [
        for (var i = 0; i < 600; i++)
          _shift('s$i', 'alice-id', _at(week, i % 7, 9), _at(week, i % 7, 10)),
      ];
      final input = build(shifts: many);
      expect(input.text.length, lessThanOrEqualTo(18000));
      expect(input.tooLarge, isFalse);
    });

    test('approvedTimeOff tolerates missing and reversed dates', () {
      final spans = approvedTimeOff([
        _request('a', '2026-10-30', '2026-10-28'),
        StaffRequest(
          id: 'x',
          venueId: 'v',
          organizationId: 'o',
          userId: 'a',
          kind: StaffRequestKind.timeOff,
          status: StaffRequestStatus.approved,
          title: 'No dates',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
        StaffRequest(
          id: 'y',
          venueId: 'v',
          organizationId: 'o',
          userId: 'a',
          kind: StaffRequestKind.sickLeave,
          status: StaffRequestStatus.approved,
          title: 'One day',
          requestedForDate: '2026-10-29',
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        ),
      ]);
      expect(spans, hasLength(2));
      expect(spans.first.to, spans.first.from);
      expect(spans.last.from, DateTime.utc(2026, 10, 29));
    });
  });

  group('resolving the answer', () {
    final roster = DraftRoster(const [_alice, _bob]);

    test('drops unknown keys and unreadable times, keeps open shifts', () {
      final outcome = resolveDraftShifts(
        const ScheduleDraftResult([
          ScheduleDraftShift(
            staffId: 'staff_1',
            roleLabel: 'Server',
            startTime: '2026-10-30T17:00',
            endTime: '2026-10-30T23:00',
          ),
          ScheduleDraftShift(
            staffId: 'staff_9',
            startTime: '2026-10-30T17:00',
            endTime: '2026-10-30T23:00',
          ),
          ScheduleDraftShift(
            staffId: 'alice-id',
            startTime: '2026-10-30T17:00',
            endTime: '2026-10-30T23:00',
          ),
          ScheduleDraftShift(
            staffId: 'staff_2',
            startTime: 'Friday evening',
            endTime: '2026-10-30T23:00',
          ),
          ScheduleDraftShift(
            staffId: '',
            roleLabel: 'Host',
            startTime: '2026-10-30T17:00',
            endTime: '2026-10-30T22:00',
          ),
        ]),
        roster,
        _clock,
      );
      expect(outcome.shifts, hasLength(2));
      expect(outcome.shifts.first.member?.userId, 'alice-id');
      expect(outcome.shifts.last.member, isNull);
      expect(outcome.droppedUnknownStaff, 2);
      expect(outcome.droppedBadTimes, 1);
    });

    test('a time with an offset is converted to the venue clock', () {
      final outcome = resolveDraftShifts(
        const ScheduleDraftResult([
          ScheduleDraftShift(
            staffId: 'staff_1',
            startTime: '2026-10-30T22:00:00Z',
            endTime: '2026-10-31T04:00:00Z',
          ),
        ]),
        roster,
        _clock,
      );
      expect(outcome.shifts.single.start, DateTime.utc(2026, 10, 30, 17));
    });

    test('parsers tolerate missing fields, junk rows and out-of-range numbers',
        () {
      final result = ScheduleDraftResult.fromJson({
        'shifts': [
          'junk',
          {'staff_id': 3, 'start_time': 5, 'extra': true},
          {'staff_id': 'staff_1', 'reason': 'x' * 900},
        ],
      });
      expect(result.shifts, hasLength(2));
      expect(result.shifts.first.staffId, '3');
      expect(result.shifts.last.reason.length, 240);
      expect(ScheduleDraftResult.fromJson(const {}).shifts, isEmpty);
      expect(
        ScheduleDraftResult.fromJson({
          'shifts': List.generate(500, (_) => {'staff_id': 'staff_1'}),
        }).shifts.length,
        ScheduleDraftResult.maxShifts,
      );
    });
  });

  group('warnings', () {
    final week = DateTime.utc(2026, 10, 26);
    final now = DateTime.utc(2026, 10, 24, 12);

    DraftShift draft(
      int id,
      RosterMember? who,
      DateTime start,
      DateTime end,
    ) =>
        DraftShift(
          id: id,
          member: who,
          roleLabel: 'Server',
          start: start,
          end: end,
        );

    Map<int, List<DraftWarning>> warn(
      List<DraftShift> drafts, {
      Set<int>? selected,
      List<Shift> existing = const [],
      List<TimeOffSpan> timeOff = const [],
      int maxHours = 40,
      DateTime? nowWall,
    }) =>
        draftWarnings(
          drafts: drafts,
          selected: selected ?? {for (final d in drafts) d.id},
          existing: existing,
          timeOff: timeOff,
          clock: _clock,
          weekStartWall: week,
          maxHours: maxHours,
          nowWall: nowWall ?? now,
        );

    Set<DraftWarningKind> kinds(Map<int, List<DraftWarning>> w, int id) =>
        {for (final x in w[id] ?? const <DraftWarning>[]) x.kind};

    test('a clean proposal has no warnings', () {
      final w = warn([draft(0, _alice, _at(week, 4, 17), _at(week, 4, 23))]);
      expect(w, isEmpty);
    });

    test('overlap with an existing shift', () {
      final w = warn(
        [draft(0, _alice, _at(week, 4, 17), _at(week, 4, 23))],
        existing: [_shift('e', 'alice-id', _at(week, 4, 20), _at(week, 5, 2))],
      );
      expect(kinds(w, 0), {DraftWarningKind.overlapsExisting});
      // Someone else's shift, or a cancelled one, is no clash.
      expect(
        warn(
          [draft(0, _alice, _at(week, 4, 17), _at(week, 4, 23))],
          existing: [
            _shift('e', 'bob-id', _at(week, 4, 20), _at(week, 5, 2)),
            _shift(
              'f',
              'alice-id',
              _at(week, 4, 20),
              _at(week, 5, 2),
              status: ShiftStatus.cancelled,
            ),
          ],
        ),
        isEmpty,
      );
    });

    test('overlap between selected proposals only', () {
      final drafts = [
        draft(0, _alice, _at(week, 4, 17), _at(week, 4, 23)),
        draft(1, _alice, _at(week, 4, 20), _at(week, 5, 1)),
      ];
      expect(kinds(warn(drafts), 0), {DraftWarningKind.overlapsDraft});
      expect(kinds(warn(drafts), 1), {DraftWarningKind.overlapsDraft});
      // An unticked proposal is judged as if added, but never blocks the ticked one.
      expect(warn(drafts, selected: {1})[1], isNull);
    });

    test('more than the weekly limit counts existing hours too', () {
      final drafts = [draft(0, _alice, _at(week, 4, 12), _at(week, 4, 23))];
      final existing = [
        for (var d = 0; d < 3; d++)
          _shift('e$d', 'alice-id', _at(week, d, 9), _at(week, d, 19)),
      ];
      final w = warn(drafts, existing: existing, maxHours: 40);
      expect(kinds(w, 0), {DraftWarningKind.overHours});
      expect(w[0]!.single.message, contains('40h'));
      expect(warn(drafts, existing: existing, maxHours: 45), isEmpty);
    });

    test('shift on approved time off', () {
      final w = warn(
        [draft(0, _alice, _at(week, 4, 17), _at(week, 4, 23))],
        timeOff: [
          TimeOffSpan(
            userId: 'alice-id',
            from: DateTime.utc(2026, 10, 30),
            to: DateTime.utc(2026, 10, 31),
          ),
        ],
      );
      expect(kinds(w, 0), {DraftWarningKind.onTimeOff});
    });

    test('a shift running past midnight into time off is caught', () {
      final w = warn(
        [draft(0, _alice, _at(week, 3, 20), _at(week, 4, 2))],
        timeOff: [
          TimeOffSpan(
            userId: 'alice-id',
            from: DateTime.utc(2026, 10, 30),
            to: DateTime.utc(2026, 10, 30),
          ),
        ],
      );
      expect(kinds(w, 0), {DraftWarningKind.onTimeOff});
    });

    test('past, outside the week, very long and invalid', () {
      final w = warn(
        [
          draft(0, _alice, _at(week, 4, 17), _at(week, 4, 23)),
          draft(1, _alice, _at(week, 8, 17), _at(week, 8, 23)),
          draft(2, _alice, _at(week, 5, 6), _at(week, 5, 23)),
          draft(3, _alice, _at(week, 6, 17), _at(week, 6, 16)),
        ],
        nowWall: _at(week, 5, 0),
      );
      expect(kinds(w, 0), {DraftWarningKind.inPast});
      expect(
        kinds(w, 1),
        containsAll([DraftWarningKind.outsideWeek]),
      );
      expect(kinds(w, 2), {DraftWarningKind.veryLong});
      expect(kinds(w, 3), {DraftWarningKind.invalidTime});
      expect(w[3]!.single.blocking, isTrue);
      expect(w[0]!.single.blocking, isFalse);
    });

    test('open shifts are never checked against a person', () {
      expect(
        warn([draft(0, null, _at(week, 4, 17), _at(week, 4, 23))]),
        isEmpty,
      );
    });
  });

  group('review screen', () {
    testWidgets('proposals are previewed and only selected ones are created',
        (tester) async {
      final h = await _pumpDraft(tester, requests: _timeOffForBob);
      await _draftIt(tester);

      // Reading the answer created nothing.
      expect(h.repo.created, isEmpty);
      expect(find.text('Review drafted shifts'), findsOneWidget);
      expect(find.textContaining('Alice Adams · Server'), findsOneWidget);
      expect(find.textContaining('Bob Brown · Server'), findsOneWidget);
      expect(find.text('Open shift · Host'), findsOneWidget);
      expect(
        find.text('This person has approved time off on this day.'),
        findsOneWidget,
      );
      // Bob's proposal has a warning, so it is not pre-ticked.
      expect(find.text('Add selected (2)'), findsOneWidget);

      // The assistant got keys and the week, never ids.
      expect(h.ai.lastInput, contains('staff_2'));
      expect(h.ai.lastInput, isNot(contains('alice-id')));
      expect(h.ai.lastInput, contains(wallDateKey(_defaultWeek())));

      await tester.tap(find.text('Add selected (2)'));
      await tester.pumpAndSettle();
      expect(h.repo.created.map((c) => c.staffId), ['alice-id', null]);
      expect(h.repo.created.first.role, 'Server');
      expect(
        _clock.wall(h.repo.created.first.start),
        _at(_defaultWeek(), 4, 17),
      );
      expect(find.text('Added 2 shifts.'), findsOneWidget);
    });

    testWidgets('unticking a proposal keeps it out of the schedule',
        (tester) async {
      final h = await _pumpDraft(tester);
      await _draftIt(tester);
      await tester.tap(find.byType(Checkbox).first);
      await tester.pumpAndSettle();
      expect(find.textContaining('Add selected ('), findsOneWidget);
      await tester.tap(find.textContaining('Add selected ('));
      await tester.pumpAndSettle();
      expect(h.repo.created.map((c) => c.staffId), isNot(contains('alice-id')));
    });

    testWidgets('a person who is not on the roster is dropped and noted',
        (tester) async {
      final week = _defaultWeek();
      await _pumpDraft(
        tester,
        answer: ScheduleDraftResult([
          ScheduleDraftShift(
            staffId: 'staff_1',
            roleLabel: 'Server',
            startTime: wallDateTimeKey(_at(week, 4, 17)),
            endTime: wallDateTimeKey(_at(week, 4, 23)),
          ),
          ScheduleDraftShift(
            staffId: 'staff_77',
            roleLabel: 'Server',
            startTime: wallDateTimeKey(_at(week, 4, 17)),
            endTime: wallDateTimeKey(_at(week, 4, 23)),
          ),
        ]),
      );
      await _draftIt(tester);
      expect(
        find.textContaining('1 naming someone not on the roster'),
        findsOneWidget,
      );
      expect(find.textContaining('Alice Adams · Server'), findsOneWidget);
    });

    testWidgets('overlaps with the existing schedule and the hours limit show',
        (tester) async {
      final week = _defaultWeek();
      await _pumpDraft(
        tester,
        shifts: [
          _shift('e', 'alice-id', _at(week, 4, 20), _at(week, 5, 2)),
          for (var d = 0; d < 4; d++)
            _shift('w$d', 'bob-id', _at(week, d, 9), _at(week, d, 19)),
        ],
      );
      await _draftIt(tester);
      expect(
        find.text('Overlaps a shift this person already has.'),
        findsOneWidget,
      );
      expect(find.textContaining('this week (limit 40h)'), findsOneWidget);
      // Both flagged proposals start unticked: only the open shift is picked.
      expect(find.text('Add selected (1)'), findsOneWidget);
    });

    testWidgets('AI disabled: the reason shows in place and nothing is created',
        (tester) async {
      final h = await _pumpDraft(
        tester,
        error: const AiUnavailableError(
          'AI features are turned off for this organization.',
        ),
      );
      await _draftIt(tester);
      expect(
        find.text('AI features are turned off for this organization.'),
        findsOneWidget,
      );
      // The form and the typed rules are still there, with the manual way out.
      expect(find.text('Two servers Friday night'), findsOneWidget);
      expect(find.text('Add shifts manually instead'), findsOneWidget);
      expect(h.repo.created, isEmpty);
      await tester.tap(find.text('Add shifts manually instead'));
      await tester.pumpAndSettle();
      expect(find.text('Draft a week'), findsNothing);
    });

    testWidgets('an empty description is refused before anything is sent',
        (tester) async {
      final h = await _pumpDraft(tester);
      await tester.tap(find.text('Draft shifts'));
      await tester.pumpAndSettle();
      expect(find.text('Describe the week you need first.'), findsOneWidget);
      expect(h.ai.lastInput, isNull);
    });

    testWidgets('a failed create stays on its line and keeps the selection',
        (tester) async {
      final h = await _pumpDraft(tester);
      h.repo.failFor = 'bob-id';
      await _draftIt(tester);
      expect(find.text('Add selected (3)'), findsOneWidget);

      await tester.tap(find.text('Add selected (3)'));
      await tester.pumpAndSettle();

      // The other two were added; Bob's refused one is explained in place and still ticked.
      expect(h.repo.created.map((c) => c.staffId), ['alice-id', null]);
      expect(find.text('Added to the schedule'), findsNWidgets(2));
      expect(
        find.text("You don't have permission to schedule shifts here."),
        findsOneWidget,
      );
      expect(find.text('Add selected (1)'), findsOneWidget);
      expect(find.textContaining('1 could not be added'), findsOneWidget);
      expect(find.text('Review drafted shifts'), findsOneWidget);

      // Retrying sends only the one that is still selected.
      h.repo.failFor = null;
      await tester.tap(find.text('Add selected (1)'));
      await tester.pumpAndSettle();
      expect(h.repo.created.map((c) => c.staffId), [
        'alice-id',
        null,
        'bob-id',
      ]);
    });

    testWidgets('editing a proposal changes what is created', (tester) async {
      final h = await _pumpDraft(tester);
      await _draftIt(tester);
      await tester.tap(find.byTooltip('Edit shift').first);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Role (e.g. bartender)'),
        'Bartender',
      );
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.tap(find.textContaining('Add selected ('));
      await tester.pumpAndSettle();
      expect(h.repo.created.first.role, 'Bartender');
    });
  });
}

final _timeOffForBob = [
  _request(
    'bob-id',
    wallDateKey(_at(_defaultWeek(), 4, 0)),
    wallDateKey(_at(_defaultWeek(), 4, 0)),
  ),
];

class _Repo implements SchedulesRepository {
  _Repo(this.shifts);

  final List<Shift> shifts;
  String? failFor;
  final created =
      <({String? staffId, String? role, DateTime start, DateTime end})>[];

  @override
  Future<List<Shift>> fetchShiftsForVenue(String venueId) async => shifts;

  @override
  Future<void> createShift({
    required String venueId,
    String? staffId,
    String? roleLabel,
    String? section,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    if (failFor != null && staffId == failFor) {
      throw const PostgrestException(message: 'denied', code: '42501');
    }
    created.add(
      (staffId: staffId, role: roleLabel, start: startTime, end: endTime),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Ai implements AiRepository {
  _Ai({this.answer, this.error});

  final ScheduleDraftResult? answer;
  final AppError? error;
  String? lastInput;

  @override
  Future<ScheduleDraftResult> draftSchedule({
    required String venueId,
    required String context,
  }) async {
    lastInput = context;
    if (error != null) throw error!;
    return answer!;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

typedef _Harness = ({_Repo repo, _Ai ai});

Future<_Harness> _pumpDraft(
  WidgetTester tester, {
  ScheduleDraftResult? answer,
  AppError? error,
  List<Shift> shifts = const [],
  List<StaffRequest> requests = const [],
}) async {
  tester.view.physicalSize = const Size(900, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final week = _defaultWeek();
  final ai = _Ai(
    error: error,
    answer: answer ??
        ScheduleDraftResult([
          ScheduleDraftShift(
            staffId: 'staff_1',
            roleLabel: 'Server',
            startTime: wallDateTimeKey(_at(week, 4, 17)),
            endTime: wallDateTimeKey(_at(week, 4, 23)),
            reason: 'Usually works Fridays',
          ),
          ScheduleDraftShift(
            staffId: 'staff_2',
            roleLabel: 'Server',
            startTime: wallDateTimeKey(_at(week, 4, 17)),
            endTime: wallDateTimeKey(_at(week, 4, 23)),
          ),
          ScheduleDraftShift(
            staffId: '',
            roleLabel: 'Host',
            startTime: wallDateTimeKey(_at(week, 1, 17)),
            endTime: wallDateTimeKey(_at(week, 1, 22)),
          ),
        ]),
  );
  final repo = _Repo(shifts);
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org',
    name: 'Venue',
    timezone: 'America/Chicago',
    createdAt: DateTime(2026),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeVenueProvider.overrideWith((ref) => venue),
        schedulesRepositoryProvider.overrideWithValue(repo),
        scheduleRosterForVenueProvider.overrideWith(
          (ref, venueId) async => const [_alice, _bob],
        ),
        staffRequestsForVenueProvider
            .overrideWith((ref, venueId) async => requests),
        aiRepositoryProvider.overrideWithValue(ai),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        const ScheduleDraftScreen(venueId: 'venue-1'),
                  ),
                ),
                child: const Text('Open draft'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open draft'));
  await tester.pumpAndSettle();
  return (repo: repo, ai: ai);
}

Future<void> _draftIt(WidgetTester tester) async {
  await tester.enterText(
    find.widgetWithText(TextField, 'Rules for the week'),
    'Two servers Friday night',
  );
  await tester.tap(find.text('Draft shifts'));
  await tester.pumpAndSettle();
}
