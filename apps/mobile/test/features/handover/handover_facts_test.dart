import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/handover/domain/handover_facts.dart';
import 'package:venuewrangler_mobile/features/incidents/domain/incident.dart';
import 'package:venuewrangler_mobile/features/inventory/domain/inventory_v2.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/operational_task.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/time_entry.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_clock.dart';

import 'handover_fixtures.dart';

HandoverFacts gather({
  VenueClock clock = handoverClock,
  DateTime? now,
  List<Incident>? incidents = const [],
  List<OperationalTask>? tasks = const [],
  List<Shift>? shifts = const [],
  List<TimeEntry> entries = const [],
}) =>
    HandoverFacts.gather(
      HandoverInputs(
        clock: clock,
        now: now ?? handoverNow,
        incidents: incidents,
        inventory: stockSnapshot(),
        tasks: tasks,
        templates: const [],
        completedTemplateIds: const {},
        entries: entries,
        shifts: shifts,
        events: const [],
        reservations: const [],
      ),
    );

void main() {
  group('window', () {
    test('after midnight still belongs to the previous business day', () {
      final facts = gather();
      expect(facts.venueDate, DateTime.utc(2026, 10, 24));
      expect(facts.windowStartUtc, DateTime.utc(2026, 10, 24, 6));
      expect(facts.windowEndUtc, DateTime.utc(2026, 10, 25, 6));
    });

    test('uses the venue clock, not UTC', () {
      // 03:00 UTC Oct 25 is 23:00 Oct 24 in New York (EDT).
      final facts = gather(
        clock: const VenueClock('America/New_York'),
        now: DateTime.utc(2026, 10, 25, 3),
      );
      expect(facts.venueDate, DateTime.utc(2026, 10, 24));
      expect(facts.windowStartUtc, DateTime.utc(2026, 10, 24, 10));
    });
  });

  group('sections', () {
    test('incidents: tonight plus unresolved carry-overs, worst first', () {
      final facts = gather(
        incidents: [
          incident('a', 'Slip', IncidentSeverity.low),
          incident(
            'b',
            'Old open',
            IncidentSeverity.medium,
            at: DateTime.utc(2026, 10, 20),
          ),
          incident(
            'c',
            'Old resolved',
            IncidentSeverity.high,
            status: IncidentStatus.resolved,
            at: DateTime.utc(2026, 10, 20),
          ),
          incident('d', 'Fire alarm', IncidentSeverity.critical),
        ],
      );
      expect(
        facts.incidents.map((i) => i.title),
        ['Fire alarm', 'Old open', 'Slip'],
      );
      expect(facts.incidents[1].carriedOver, isTrue);
    });

    test('stock: out and low only, out first', () {
      final facts = gather();
      expect(
        facts.stock.map((s) => '${s.name}:${s.out}'),
        ['Tito\'s Vodka:true', 'Limes:false'],
      );
    });

    test('tasks: due tonight, overdue or in progress vs open to-dos', () {
      final facts = gather(
        tasks: [
          task('1', 'Overdue', due: DateTime.utc(2026, 10, 24, 20)),
          task('2', 'Later this week', due: DateTime.utc(2026, 10, 28)),
          task('3', 'No date'),
          task('4', 'Working', status: TaskStatus.inProgress),
          task('5', 'Done', status: TaskStatus.completed),
        ],
      );
      expect(facts.unfinishedTasks.map((t) => t.title), ['Overdue', 'Working']);
      expect(facts.unfinishedTasks.first.overdue, isTrue);
      expect(
        facts.openTodos.map((t) => t.title),
        ['Later this week', 'No date'],
      );
    });

    test('clock: missed clock-out, late, and no clock-in', () {
      final facts = gather(
        shifts: [
          shift(
            's1',
            'u1',
            DateTime.utc(2026, 10, 24, 17),
            DateTime.utc(2026, 10, 24, 23),
          ),
          shift(
            's2',
            'u2',
            DateTime.utc(2026, 10, 24, 18),
            DateTime.utc(2026, 10, 25, 1),
          ),
          shift(
            's3',
            'u3',
            DateTime.utc(2026, 10, 24, 18),
            DateTime.utc(2026, 10, 25, 1),
          ),
          shift(
            's4',
            'u4',
            DateTime.utc(2026, 10, 24, 18),
            DateTime.utc(2026, 10, 25, 1),
            status: ShiftStatus.cancelled,
          ),
        ],
        entries: [
          entry(
            'e1',
            'u1',
            DateTime.utc(2026, 10, 24, 17),
            open: true,
            shiftId: 's1',
          ),
          entry(
            'e2',
            'u2',
            DateTime.utc(2026, 10, 24, 18, 25),
            clockOut: DateTime.utc(2026, 10, 25),
            shiftId: 's2',
          ),
        ],
      );
      final kinds = {for (final c in facts.clockExceptions) c.kind};
      expect(kinds, {'missed_clock_out', 'late', 'no_clock_in'});
      // u4's shift was cancelled, so no exception for them; three people appear.
      expect(facts.people.length, 3);
      expect(facts.people.keys, ['staff_1', 'staff_2', 'staff_3']);
      final late = facts.clockExceptions.firstWhere((c) => c.kind == 'late');
      expect(late.detail, contains('25 min'));
    });

    test('a person on time and clocked out is not an exception', () {
      final facts = gather(
        shifts: [
          shift(
            's1',
            'u1',
            DateTime.utc(2026, 10, 24, 17),
            DateTime.utc(2026, 10, 24, 23),
          ),
        ],
        entries: [
          entry(
            'e1',
            'u1',
            DateTime.utc(2026, 10, 24, 17, 5),
            clockOut: DateTime.utc(2026, 10, 24, 23),
            shiftId: 's1',
          ),
        ],
      );
      expect(facts.clockExceptions, isEmpty);
    });

    test('reservations: counts, covers, no-shows, holds, large parties', () {
      final facts = HandoverFacts.gather(
        HandoverInputs(
          clock: handoverClock,
          now: handoverNow,
          reservations: [
            reservation('1', DateTime.utc(2026, 10, 24, 19), 4),
            reservation('2', DateTime.utc(2026, 10, 24, 20), 10),
            reservation(
              '3',
              DateTime.utc(2026, 10, 24, 21),
              2,
              status: 'no_show',
            ),
            reservation(
              '4',
              DateTime.utc(2026, 10, 24, 21),
              6,
              status: 'cancelled',
            ),
            reservation('5', DateTime.utc(2026, 10, 24, 19), 40, beoId: 'b'),
            reservation('6', DateTime.utc(2026, 10, 26, 19), 3),
          ],
        ),
      );
      final r = facts.reservations;
      expect(r.count, 3);
      expect(r.covers, 14);
      expect(r.noShows, 1);
      expect(r.privateEventHolds, 1);
      expect(r.largeParties, ['8:00 PM party of 10']);
    });

    test('a section that failed to load is unavailable, never "clear"', () {
      final facts = HandoverFacts.gather(
        HandoverInputs(clock: handoverClock, now: handoverNow),
      );
      expect(facts.unavailable, hasLength(7));
      expect(facts.isQuiet, isFalse);
      final text = facts.toPlainText();
      expect(text, contains('Could not load this; check it by hand.'));
      expect(text, isNot(contains('Nothing to report.')));
    });
  });

  group('payload and text', () {
    test('AI payload has no names, ids, pay or guest details', () {
      final json = busyFacts().toPromptJson();
      expect(json, isNot(contains('Maya')));
      expect(json, isNot(contains('Secret Guest')));
      expect(json, isNot(contains('555-0100')));
      expect(json, isNot(contains('u1')));
      final data = jsonDecode(json) as Map<String, dynamic>;
      final clock =
          (data['clock_exceptions'] as List).cast<Map<String, dynamic>>();
      expect(clock.first['person'], 'staff_1');
      expect((data['reservations'] as Map<String, dynamic>)['covers'], 14);
      expect(
        (data['incidents'] as List)
            .cast<Map<String, dynamic>>()
            .first['severity'],
        'high',
      );
    });

    test('plain text names people and lists every section', () {
      final text = busyFacts().toPlainText(venueName: 'The Barn');
      expect(text, startsWith('Shift handover - The Barn (Sat, Oct 24, 2026)'));
      expect(text, contains('[HIGH] Fight at the bar (open)'));
      expect(text, contains('Tito\'s Vodka: out'));
      expect(text, contains('Closing checklist'));
      expect(text, contains('Maya Lopez: still clocked in since 5:00 PM'));
      expect(text, contains('Whitmore party, 7:00 PM to 11:00 PM'));
      expect(text, contains('7:30 PM party of 12'));
      expect(text, contains('Order limes'));
    });

    test('resolvePeople swaps keys for names, leaving unknown keys alone', () {
      final facts = busyFacts();
      expect(
        facts.resolvePeople('staff_1 forgot to clock out; ask staff_9.'),
        'Maya Lopez forgot to clock out; ask staff_9.',
      );
    });

    test('an all-quiet night is recognised', () {
      final facts = HandoverFacts.gather(
        HandoverInputs(
          clock: handoverClock,
          now: handoverNow,
          incidents: const [],
          inventory: InventorySnapshot(
            items: [],
            categories: [],
            subcategories: [],
            areas: [],
            subAreas: [],
            stock: [],
            counts: [],
            history: [],
          ),
          tasks: [],
          templates: [],
          completedTemplateIds: {},
          entries: [],
          shifts: [],
          events: [],
          reservations: [],
        ),
      );
      expect(facts.isQuiet, isTrue);
    });
  });
}
