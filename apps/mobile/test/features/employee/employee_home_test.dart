import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/employee/application/employee_providers.dart';
import 'package:venuewrangler_mobile/features/employee/domain/employee_day.dart';
import 'package:venuewrangler_mobile/features/employee/presentation/employee_home_screen.dart';
import 'package:venuewrangler_mobile/features/floor/application/floor_providers.dart';
import 'package:venuewrangler_mobile/features/floor/domain/floor_table.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/domain/reservation.dart';
import 'package:venuewrangler_mobile/features/notifications/application/notifications_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/application/schedules_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/data/schedules_repository.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/tasks/application/tasks_providers.dart';
import 'package:venuewrangler_mobile/features/tasks/data/tasks_repository.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/operational_task.dart';
import 'package:venuewrangler_mobile/features/time_clock/application/time_clock_providers.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

Reservation _res(
  String id,
  String guest,
  DateTime at, {
  String? assignedTo,
  int party = 2,
  String status = 'confirmed',
}) =>
    Reservation(
      id: id,
      organizationId: 'o',
      venueId: 'venue-1',
      guestName: guest,
      partySize: party,
      reservationTime: at,
      status: status,
      assignedTo: assignedTo,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

FloorTable _table(String id, String label, String section, String status) {
  final t = DateTime(2026);
  return FloorTable(
    id: id,
    organizationId: 'o',
    venueId: 'venue-1',
    floorPlanId: 'p',
    label: label,
    section: section,
    status: status,
    lastActivityAt: t,
    createdAt: t,
    updatedAt: t,
  );
}

OperationalTask _task(
  String id,
  String title, {
  String? assignedTo,
  TaskStatus status = TaskStatus.open,
  DateTime? completedAt,
}) =>
    OperationalTask(
      id: id,
      venueId: 'venue-1',
      organizationId: 'o',
      title: title,
      status: status,
      assignedTo: assignedTo,
      completedAt: completedAt,
      createdAt: DateTime(2026),
      updatedAt: DateTime(2026),
    );

class _Store implements OfflineQueueStore {
  List<PendingMutation> saved = const [];

  @override
  Future<List<PendingMutation>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<PendingMutation> m) async => saved = m;
}

class _Schedules implements SchedulesRepository {
  _Schedules(this.shifts);

  final List<Shift> shifts;

  @override
  Future<List<Shift>> fetchShiftsForVenue(String venueId) async => shifts;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _Tasks implements TasksRepository {
  _Tasks(this.tasks);

  final List<OperationalTask> tasks;

  @override
  Future<List<OperationalTask>> fetchTasksForVenue(String venueId) async =>
      tasks;

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  final evening = DateTime(2026, 10, 6, 19);

  group('employee day', () {
    test('my reservations: today, assigned to me, not cancelled, by time', () {
      final list = myReservationsToday(
        [
          _res('a', 'Late', DateTime(2026, 10, 6, 21), assignedTo: 'me'),
          _res('b', 'Early', DateTime(2026, 10, 6, 18), assignedTo: 'me'),
          _res('c', 'Theirs', DateTime(2026, 10, 6, 18), assignedTo: 'you'),
          _res(
            'd',
            'Gone',
            DateTime(2026, 10, 6, 20),
            assignedTo: 'me',
            status: 'cancelled',
          ),
          _res('e', 'Tomorrow', DateTime(2026, 10, 7, 19), assignedTo: 'me'),
          // 1am still belongs to tonight's business day.
          _res(
            'f',
            'After midnight',
            DateTime(2026, 10, 7, 1),
            assignedTo: 'me',
          ),
        ],
        'me',
        evening,
      );
      expect(list.map((r) => r.id), ['b', 'a', 'f']);
    });

    test('covers count only seated or completed parties', () {
      final mine = [
        _res('a', 'A', evening, party: 4, status: 'seated'),
        _res('b', 'B', evening, party: 3, status: 'completed'),
        _res('c', 'C', evening, party: 6),
      ];
      expect(coversToday(mine), 7);
    });

    test('tasks: open ones assigned to me, and how many I finished today', () {
      final tasks = [
        _task('1', 'Mine', assignedTo: 'me'),
        _task('2', 'Theirs', assignedTo: 'you'),
        _task('3', 'Unassigned'),
        _task(
          '4',
          'Done today',
          assignedTo: 'me',
          status: TaskStatus.completed,
          completedAt: DateTime(2026, 10, 6, 17),
        ),
        _task(
          '5',
          'Done yesterday',
          assignedTo: 'me',
          status: TaskStatus.completed,
          completedAt: DateTime(2026, 10, 5, 17),
        ),
        _task('6', 'Ticked offline', assignedTo: 'me'),
      ];
      final pending = {'6': TaskStatus.completed};
      expect(
        myAssignedOpenTasks(tasks, 'me', pending).map((t) => t.id),
        ['1'],
      );
      expect(tasksDoneToday(tasks, 'me', pending, evening), 2);
    });

    test('section tables match case-insensitively', () {
      final tables = [
        _table('1', 'P2', 'Patio', 'seated'),
        _table('2', 'P1', 'patio ', 'available'),
        _table('3', 'B1', 'bar', 'available'),
      ];
      expect(
        tablesInSection(tables, 'PATIO').map((t) => t.label),
        ['P1', 'P2'],
      );
      expect(tablesInSection(tables, null), isEmpty);
    });
  });

  testWidgets('home shows my shift, section, reservations and tasks only',
      (tester) async {
    tester.view.physicalSize = const Size(800, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    final now = DateTime.now();
    final shift = Shift(
      id: 's1',
      venueId: 'venue-1',
      staffId: 'me',
      roleLabel: 'Server',
      section: 'Patio',
      startTime: now.subtract(const Duration(hours: 1)),
      endTime: now.add(const Duration(hours: 4)),
      status: ShiftStatus.scheduled,
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith(
            (ref) => Venue(
              id: 'venue-1',
              organizationId: 'o',
              name: 'Venue',
              createdAt: DateTime(2026),
            ),
          ),
          currentUserIdProvider.overrideWithValue('me'),
          schedulesRepositoryProvider.overrideWithValue(_Schedules([shift])),
          tasksRepositoryProvider.overrideWithValue(
            _Tasks([
              _task('t1', 'Polish glasses', assignedTo: 'me'),
              _task('t2', 'Someone else’s job', assignedTo: 'you'),
            ]),
          ),
          activeTimeEntryProvider.overrideWith((ref, id) async => null),
          todaysReservationsProvider.overrideWith(
            (ref) async => [
              _res(
                'r1',
                'Rivera',
                now,
                assignedTo: 'me',
                party: 4,
              ),
              _res(
                'r2',
                'Other guest',
                now,
                assignedTo: 'you',
              ),
            ],
          ),
          floorTablesStreamProvider.overrideWith(
            (ref) => Stream.value([
              _table('1', 'P1', 'Patio', 'seated'),
              _table('2', 'P2', 'Patio', 'available'),
              _table('3', 'B1', 'Bar', 'seated'),
            ]),
          ),
          unreadNotificationsCountProvider.overrideWithValue(0),
          offlineQueueStoreProvider.overrideWithValue(_Store()),
        ],
        child: MaterialApp(
          theme: AppTheme.dark(),
          home: const EmployeeHomeScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('On shift'), findsOneWidget);
    expect(find.text('Section: Patio'), findsOneWidget);
    expect(find.text('My section · Patio'), findsOneWidget);
    expect(find.text('P1 · Seated'), findsOneWidget);
    expect(find.text('P2 · Available'), findsOneWidget);
    expect(find.textContaining('B1'), findsNothing);
    expect(find.text('1 of 2'), findsOneWidget); // section seated KPI
    expect(find.text('Rivera'), findsOneWidget);
    expect(find.text('Other guest'), findsNothing);
    expect(find.text('Polish glasses'), findsOneWidget);
    expect(find.textContaining('Someone else'), findsNothing);
  });
}
