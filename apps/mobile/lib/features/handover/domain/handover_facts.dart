import 'dart:convert';

import '../../checklists/domain/checklist_template.dart';
import '../../events/domain/event.dart';
import '../../guests_reservations/domain/reservation.dart';
import '../../incidents/domain/incident.dart';
import '../../inventory/domain/inventory_v2.dart';
import '../../schedules/domain/shift.dart';
import '../../tasks/domain/operational_task.dart';
import '../../time_clock/domain/time_entry.dart';
import '../../venues/domain/venue_clock.dart';
import '../../venues/domain/venue_timezone.dart';

/// The facts a handover note is built from, gathered deterministically from the app's own data
/// for the venue's business day (see [HandoverFacts.gather]). The note is only ever *written* by
/// AI; what goes in it is decided here, so the screen is useful with AI off.
///
/// Sections whose data could not be loaded are listed in [unavailable] and are never reported as
/// "all clear".

/// Section keys used in [HandoverFacts.unavailable] and shown in the screen.
abstract final class HandoverSectionKey {
  static const incidents = 'incidents';
  static const stock = 'stock';
  static const tasks = 'tasks';
  static const checklists = 'checklists';
  static const clock = 'clock';
  static const events = 'events';
  static const reservations = 'reservations';

  static const labels = {
    incidents: 'Incidents',
    stock: 'Out of stock and low',
    tasks: 'Tasks',
    checklists: 'Checklists',
    clock: 'Clock exceptions',
    events: 'Events',
    reservations: 'Reservations',
  };
}

/// Raw inputs to [HandoverFacts.gather]. A null list means "could not be loaded".
class HandoverInputs {
  const HandoverInputs({
    required this.clock,
    required this.now,
    this.incidents,
    this.inventory,
    this.tasks,
    this.templates,
    this.completedTemplateIds,
    this.entries,
    this.shifts,
    this.events,
    this.reservations,
    this.staffNames = const {},
  });

  final VenueClock clock;
  final DateTime now;
  final List<Incident>? incidents;
  final InventorySnapshot? inventory;
  final List<OperationalTask>? tasks;
  final List<ChecklistTemplate>? templates;
  final Set<String>? completedTemplateIds;

  /// Entries that clocked in during the window plus any still open.
  final List<TimeEntry>? entries;
  final List<Shift>? shifts;
  final List<VenueEvent>? events;
  final List<Reservation>? reservations;

  /// userId -> display name. Names stay on the device; the AI only sees `staff_N` keys.
  final Map<String, String> staffNames;
}

class HandoverIncident {
  const HandoverIncident({
    required this.title,
    required this.severity,
    required this.status,
    required this.carriedOver,
  });

  final String title;
  final String severity;
  final String status;

  /// Reported before tonight and still unresolved.
  final bool carriedOver;
}

class HandoverStockItem {
  const HandoverStockItem({required this.name, required this.out});

  final String name;

  /// True when none is left; false when below par.
  final bool out;
}

class HandoverTask {
  const HandoverTask({
    required this.title,
    this.overdue = false,
    this.inProgress = false,
    this.due,
  });

  final String title;
  final bool overdue;
  final bool inProgress;

  /// Venue-local due time ("9:00 PM"), when the task has one.
  final String? due;
}

class HandoverClockException {
  const HandoverClockException({
    required this.personKey,
    required this.kind,
    required this.detail,
  });

  /// `staff_1`... — resolved to a name only on the device.
  final String personKey;

  /// `missed_clock_out`, `late` or `no_clock_in`.
  final String kind;
  final String detail;
}

class HandoverEvent {
  const HandoverEvent({
    required this.name,
    required this.start,
    required this.end,
    required this.status,
  });

  final String name;
  final String start;
  final String end;
  final String status;
}

class HandoverReservations {
  const HandoverReservations({
    this.count = 0,
    this.covers = 0,
    this.noShows = 0,
    this.privateEventHolds = 0,
    this.largeParties = const [],
  });

  final int count;
  final int covers;
  final int noShows;
  final int privateEventHolds;

  /// "7:30 PM party of 12" (no guest names).
  final List<String> largeParties;

  bool get isEmpty => count == 0 && privateEventHolds == 0;
}

class HandoverFacts {
  const HandoverFacts({
    required this.venueDate,
    required this.windowStartUtc,
    required this.windowEndUtc,
    required this.clock,
    this.unavailable = const [],
    this.incidents = const [],
    this.stock = const [],
    this.unfinishedTasks = const [],
    this.openTodos = const [],
    this.unsubmittedChecklists = const [],
    this.clockExceptions = const [],
    this.events = const [],
    this.reservations = const HandoverReservations(),
    this.people = const {},
    this.staffNames = const {},
  });

  /// The business date (venue wall date at midnight, UTC-flagged).
  final DateTime venueDate;
  final DateTime windowStartUtc;
  final DateTime windowEndUtc;
  final VenueClock clock;
  final List<String> unavailable;
  final List<HandoverIncident> incidents;
  final List<HandoverStockItem> stock;
  final List<HandoverTask> unfinishedTasks;
  final List<HandoverTask> openTodos;
  final List<String> unsubmittedChecklists;
  final List<HandoverClockException> clockExceptions;
  final List<HandoverEvent> events;
  final HandoverReservations reservations;

  /// `staff_N` -> userId, for the keys used in [clockExceptions].
  final Map<String, String> people;
  final Map<String, String> staffNames;

  static const _maxItems = 15;
  static const _severityRank = {
    'critical': 0,
    'high': 1,
    'medium': 2,
    'low': 3,
  };

  bool isAvailable(String section) => !unavailable.contains(section);

  /// True when every section loaded and there is nothing to report.
  bool get isQuiet =>
      unavailable.isEmpty &&
      incidents.isEmpty &&
      stock.isEmpty &&
      unfinishedTasks.isEmpty &&
      openTodos.isEmpty &&
      unsubmittedChecklists.isEmpty &&
      clockExceptions.isEmpty &&
      events.isEmpty &&
      reservations.isEmpty;

  String personLabel(String key) {
    final id = people[key];
    return (id == null ? null : staffNames[id]) ?? 'a team member';
  }

  /// Replaces `staff_N` keys in [text] (an AI draft) with names, on this device only.
  String resolvePeople(String text) => text.replaceAllMapped(
        RegExp(r'\bstaff_\d+\b'),
        (m) => people.containsKey(m.group(0))
            ? personLabel(m.group(0)!)
            : m.group(0)!,
      );

  static HandoverFacts gather(HandoverInputs input) {
    final clock = input.clock;
    final now = input.now;
    final date = clock.businessDate(now);
    final range = clock.businessDayRange(date);
    final start = range.startUtc;
    final end = range.endUtc;
    bool inWindow(DateTime t) => !t.isBefore(start) && t.isBefore(end);

    final unavailable = <String>[
      if (input.incidents == null) HandoverSectionKey.incidents,
      if (input.inventory == null) HandoverSectionKey.stock,
      if (input.tasks == null) HandoverSectionKey.tasks,
      if (input.templates == null || input.completedTemplateIds == null)
        HandoverSectionKey.checklists,
      if (input.entries == null || input.shifts == null)
        HandoverSectionKey.clock,
      if (input.events == null) HandoverSectionKey.events,
      if (input.reservations == null) HandoverSectionKey.reservations,
    ];

    // --- incidents
    final incidents = <HandoverIncident>[];
    for (final i in input.incidents ?? const <Incident>[]) {
      final tonight = inWindow(i.createdAt);
      final unresolved = i.status == IncidentStatus.open ||
          i.status == IncidentStatus.investigating;
      if (tonight || (unresolved && i.createdAt.isBefore(start))) {
        incidents.add(
          HandoverIncident(
            title: _clip(i.title, 120),
            severity: i.severity.toDb(),
            status: i.status.toDb(),
            carriedOver: !tonight,
          ),
        );
      }
    }
    incidents.sort(
      (a, b) => (_severityRank[a.severity] ?? 9)
          .compareTo(_severityRank[b.severity] ?? 9),
    );

    // --- stock
    final stock = <HandoverStockItem>[];
    final snapshot = input.inventory;
    if (snapshot != null) {
      for (final item in snapshot.items) {
        if (!item.active) continue;
        final positions = [
          for (final s in snapshot.activePositions)
            if (s.itemId == item.id && s.quantity != null) s,
        ];
        if (positions.isEmpty) continue;
        final total = snapshot.totalFor(item.id);
        if (total <= BigInt.zero) {
          stock.add(HandoverStockItem(name: _clip(item.name, 80), out: true));
        } else if (positions.any((s) => s.status == InventoryStockStatus.low)) {
          stock.add(HandoverStockItem(name: _clip(item.name, 80), out: false));
        }
      }
      stock.sort((a, b) => a.out == b.out ? 0 : (a.out ? -1 : 1));
    }

    // --- tasks
    final unfinished = <HandoverTask>[];
    final todos = <HandoverTask>[];
    for (final t in input.tasks ?? const <OperationalTask>[]) {
      final open =
          t.status == TaskStatus.open || t.status == TaskStatus.inProgress;
      if (!open) continue;
      final due = t.dueAt;
      final overdue = due != null && due.isBefore(now);
      final task = HandoverTask(
        title: _clip(t.title, 120),
        overdue: overdue,
        inProgress: t.status == TaskStatus.inProgress,
        due: due == null ? null : clock.formatTime(due),
      );
      if (due != null && due.isBefore(end) ||
          t.status == TaskStatus.inProgress) {
        unfinished.add(task);
      } else {
        todos.add(task);
      }
    }

    // --- checklists
    final unsubmitted = <String>[
      if (input.templates != null && input.completedTemplateIds != null)
        for (final t in input.templates!)
          if (!input.completedTemplateIds!.contains(t.id)) _clip(t.title, 80),
    ];

    // --- clock exceptions
    final people = <String, String>{};
    String keyFor(String userId) {
      for (final e in people.entries) {
        if (e.value == userId) return e.key;
      }
      final key = 'staff_${people.length + 1}';
      people[key] = userId;
      return key;
    }

    final exceptions = <HandoverClockException>[];
    final entries = input.entries;
    final shifts = input.shifts;
    if (entries != null && shifts != null) {
      final shiftById = {for (final s in shifts) s.id: s};
      for (final e in entries) {
        final shift = e.shiftId == null ? null : shiftById[e.shiftId];
        if (e.isOpen) {
          final shiftEnded = shift != null &&
              now.isAfter(shift.endTime.add(const Duration(minutes: 30)));
          final tooLong =
              now.difference(e.clockInAt) >= const Duration(hours: 12);
          if (shiftEnded || tooLong) {
            exceptions.add(
              HandoverClockException(
                personKey: keyFor(e.userId),
                kind: 'missed_clock_out',
                detail: shiftEnded
                    ? 'still clocked in since ${clock.formatTime(e.clockInAt)}; '
                        'shift ended ${clock.formatTime(shift.endTime)}'
                    : 'still clocked in since ${clock.formatTime(e.clockInAt)}',
              ),
            );
          }
        }
        if (shift != null) {
          final late = e.clockInAt.difference(shift.startTime);
          if (late > const Duration(minutes: 10)) {
            exceptions.add(
              HandoverClockException(
                personKey: keyFor(e.userId),
                kind: 'late',
                detail: 'clocked in ${late.inMinutes} min after the '
                    '${clock.formatTime(shift.startTime)} shift start',
              ),
            );
          }
        }
      }
      for (final s in shifts) {
        final staff = s.staffId;
        if (staff == null ||
            s.status != ShiftStatus.scheduled ||
            !inWindow(s.startTime) ||
            now.isBefore(s.startTime.add(const Duration(minutes: 30)))) {
          continue;
        }
        final clocked = entries.any(
          (e) =>
              e.userId == staff &&
              (e.shiftId == s.id ||
                  (!e.clockInAt.isBefore(
                        s.startTime.subtract(const Duration(hours: 2)),
                      ) &&
                      e.clockInAt.isBefore(s.endTime))),
        );
        if (!clocked) {
          exceptions.add(
            HandoverClockException(
              personKey: keyFor(staff),
              kind: 'no_clock_in',
              detail:
                  'no clock-in for the ${clock.formatTime(s.startTime)} shift',
            ),
          );
        }
      }
    }

    // --- events
    final events = <HandoverEvent>[
      for (final e in input.events ?? const <VenueEvent>[])
        if (e.status != EventStatus.cancelled &&
            e.startTime.isBefore(end) &&
            e.endTime.isAfter(start))
          HandoverEvent(
            name: _clip(e.name, 80),
            start: clock.formatTime(e.startTime),
            end: clock.formatTime(e.endTime),
            status: e.status.toDb(),
          ),
    ];

    // --- reservations
    var count = 0, covers = 0, noShows = 0, holds = 0;
    final large = <String>[];
    for (final r in input.reservations ?? const <Reservation>[]) {
      if (!inWindow(r.reservationTime) || r.status == 'cancelled') continue;
      if (r.isPrivateEventHold) {
        holds++;
        continue;
      }
      count++;
      if (r.status == 'no_show') {
        noShows++;
        continue;
      }
      covers += r.partySize;
      if (r.partySize >= 8 && large.length < 8) {
        large.add(
          '${clock.formatTime(r.reservationTime)} party of ${r.partySize}',
        );
      }
    }

    return HandoverFacts(
      venueDate: date,
      windowStartUtc: start,
      windowEndUtc: end,
      clock: clock,
      unavailable: unavailable,
      incidents: _cap(incidents),
      stock: _cap(stock),
      unfinishedTasks: _cap(unfinished),
      openTodos: _cap(todos),
      unsubmittedChecklists: _cap(unsubmitted),
      clockExceptions: _cap(exceptions),
      events: _cap(events),
      reservations: HandoverReservations(
        count: count,
        covers: covers,
        noShows: noShows,
        privateEventHolds: holds,
        largeParties: large,
      ),
      people: people,
      staffNames: input.staffNames,
    );
  }

  static List<T> _cap<T>(List<T> list) =>
      list.length > _maxItems ? list.sublist(0, _maxItems) : list;

  static String _clip(String text, int max) {
    final t = text.trim().replaceAll(RegExp(r'\s+'), ' ');
    return t.length > max ? '${t.substring(0, max).trimRight()}…' : t;
  }

  String get dateLabel {
    const weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    return '${weekdays[venueDate.weekday - 1]}, ${VenueTimezone.formatWallDate(venueDate)}';
  }

  /// The compact payload sent to the AI: no ids, no pay, no guest or staff names (people are
  /// `staff_N` keys), no contact details. Free text is limited to incident/task/item/event
  /// titles the venue typed itself.
  String toPromptJson() => jsonEncode({
        'venue_date': dateLabel,
        'unavailable': unavailable,
        'incidents': [
          for (final i in incidents)
            {
              'title': i.title,
              'severity': i.severity,
              'status': i.status,
              'carried_over': i.carriedOver,
            },
        ],
        'stock': [
          for (final s in stock)
            {'item': s.name, 'status': s.out ? 'out' : 'low'},
        ],
        'unfinished_tasks': [
          for (final t in unfinishedTasks)
            {
              'title': t.title,
              'overdue': t.overdue,
              'in_progress': t.inProgress,
              if (t.due != null) 'due': t.due,
            },
        ],
        'unsubmitted_checklists': unsubmittedChecklists,
        'clock_exceptions': [
          for (final c in clockExceptions)
            {'person': c.personKey, 'kind': c.kind, 'detail': c.detail},
        ],
        'events': [
          for (final e in events)
            {
              'name': e.name,
              'start': e.start,
              'end': e.end,
              'status': e.status,
            },
        ],
        'reservations': {
          'count': reservations.count,
          'covers': reservations.covers,
          'no_shows': reservations.noShows,
          'private_event_holds': reservations.privateEventHolds,
          'large_parties': reservations.largeParties,
        },
        'open_todos': [for (final t in openTodos) t.title],
      });

  /// Every section as display lines, for both the facts list on screen and the plain-text
  /// fallback note. A section that could not be loaded says so instead of reading as clear.
  List<({String key, String title, List<String> lines, bool unavailable})>
      get sections {
    List<String> taskLines(List<HandoverTask> tasks) => [
          for (final t in tasks)
            [
              t.title,
              if (t.overdue)
                '(overdue${t.due == null ? '' : ', was due ${t.due}'})'
              else if (t.due != null)
                '(due ${t.due})',
              if (t.inProgress) '(in progress)',
            ].join(' '),
        ];
    final r = reservations;
    return [
      (
        key: HandoverSectionKey.incidents,
        title: 'Incidents',
        unavailable: !isAvailable(HandoverSectionKey.incidents),
        lines: [
          for (final i in incidents)
            '[${i.severity.toUpperCase()}] ${i.title} (${i.status}'
                '${i.carriedOver ? ', from an earlier day' : ''})',
        ],
      ),
      (
        key: HandoverSectionKey.stock,
        title: 'Out of stock and low',
        unavailable: !isAvailable(HandoverSectionKey.stock),
        lines: [
          for (final s in stock) '${s.name}: ${s.out ? 'out' : 'low'}',
        ],
      ),
      (
        key: HandoverSectionKey.tasks,
        title: 'Unfinished tasks',
        unavailable: !isAvailable(HandoverSectionKey.tasks),
        lines: taskLines(unfinishedTasks),
      ),
      (
        key: HandoverSectionKey.checklists,
        title: 'Checklists not submitted',
        unavailable: !isAvailable(HandoverSectionKey.checklists),
        lines: unsubmittedChecklists,
      ),
      (
        key: HandoverSectionKey.clock,
        title: 'Clock exceptions',
        unavailable: !isAvailable(HandoverSectionKey.clock),
        lines: [
          for (final c in clockExceptions)
            '${personLabel(c.personKey)}: ${c.detail}',
        ],
      ),
      (
        key: HandoverSectionKey.events,
        title: 'Events tonight',
        unavailable: !isAvailable(HandoverSectionKey.events),
        lines: [
          for (final e in events)
            '${e.name}, ${e.start} to ${e.end} (${e.status})',
        ],
      ),
      (
        key: HandoverSectionKey.reservations,
        title: 'Reservations tonight',
        unavailable: !isAvailable(HandoverSectionKey.reservations),
        lines: [
          if (!r.isEmpty) ...[
            '${r.count} reservations, ${r.covers} covers'
                '${r.noShows > 0 ? ', ${r.noShows} no-shows' : ''}',
            if (r.privateEventHolds > 0)
              '${r.privateEventHolds} private event hold(s)',
            ...r.largeParties,
          ],
        ],
      ),
      (
        key: 'todos',
        title: 'Open to-dos',
        unavailable: !isAvailable(HandoverSectionKey.tasks),
        lines: taskLines(openTodos),
      ),
    ];
  }

  /// The deterministic note used when AI is off or fails; also the starting text of the editor.
  String toPlainText({String? venueName}) {
    final buffer = StringBuffer(
      'Shift handover${venueName == null ? '' : ' - $venueName'} ($dateLabel)\n',
    );
    for (final s in sections) {
      buffer.writeln();
      buffer.writeln(s.title);
      if (s.unavailable) {
        buffer.writeln('- Could not load this; check it by hand.');
      } else if (s.lines.isEmpty) {
        buffer.writeln('- Nothing to report.');
      } else {
        for (final line in s.lines) {
          buffer.writeln('- $line');
        }
      }
    }
    return buffer.toString().trimRight();
  }
}
