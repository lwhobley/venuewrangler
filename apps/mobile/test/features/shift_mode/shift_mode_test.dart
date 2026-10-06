import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/notifications/application/notifications_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/application/schedules_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/data/schedules_repository.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/shift_mode/domain/shift_mode.dart';
import 'package:venuewrangler_mobile/features/shift_mode/presentation/shift_mode_screen.dart';
import 'package:venuewrangler_mobile/features/tasks/application/tasks_providers.dart';
import 'package:venuewrangler_mobile/features/tasks/data/tasks_repository.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/operational_task.dart';
import 'package:venuewrangler_mobile/features/time_clock/application/time_clock_providers.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

Shift _shift(
  String id,
  String? staff,
  DateTime start,
  DateTime end, {
  ShiftStatus status = ShiftStatus.scheduled,
}) =>
    Shift(
      id: id,
      venueId: 'venue-1',
      staffId: staff,
      roleLabel: 'Server',
      startTime: start,
      endTime: end,
      status: status,
    );

OperationalTask _task(
  String id,
  String title, {
  String? assignedTo,
  TaskStatus status = TaskStatus.open,
  DateTime? due,
}) =>
    OperationalTask(
      id: id,
      venueId: 'venue-1',
      organizationId: 'org',
      title: title,
      status: status,
      assignedTo: assignedTo,
      dueAt: due,
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
  final done = <String>[];

  @override
  Future<List<OperationalTask>> fetchTasksForVenue(String venueId) async =>
      tasks;

  @override
  Future<void> updateStatus(String taskId, TaskStatus status) async {
    if (status == TaskStatus.completed) done.add(taskId);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  final now = DateTime(2026, 10, 5, 19);

  group('shift mode logic', () {
    test('finds the current and next shift for one person only', () {
      final current = _shift(
        'a',
        'me',
        now.subtract(const Duration(hours: 1)),
        now.add(const Duration(hours: 3)),
      );
      final next = _shift(
        'b',
        'me',
        now.add(const Duration(days: 1)),
        now.add(const Duration(days: 1, hours: 4)),
      );
      final later = _shift(
        'c',
        'me',
        now.add(const Duration(days: 2)),
        now.add(const Duration(days: 2, hours: 4)),
      );
      final other = _shift(
        'd',
        'you',
        now.subtract(const Duration(hours: 1)),
        now.add(const Duration(hours: 3)),
      );
      final cancelled = _shift(
        'e',
        'me',
        now.add(const Duration(hours: 5)),
        now.add(const Duration(hours: 9)),
        status: ShiftStatus.cancelled,
      );
      final r = myShifts([later, other, cancelled, next, current], 'me', now);
      expect(r.current!.id, 'a');
      expect(r.next!.id, 'b');
      expect(myShifts([current], null, now).current, isNull);
    });

    test('progress and duration labels', () {
      final s = _shift('a', 'me', now, now.add(const Duration(hours: 4)));
      expect(shiftProgress(s, now.add(const Duration(hours: 1))), 0.25);
      expect(shiftProgress(s, now.subtract(const Duration(hours: 1))), 0);
      expect(durationLabel(const Duration(minutes: 130)), '2h 10m');
      expect(durationLabel(const Duration(minutes: 45)), '45m');
      expect(durationLabel(const Duration(hours: 2)), '2h');
      expect(durationLabel(Duration.zero), 'now');
    });

    test('my tasks: mine + unassigned, unfinished, overdue first', () {
      final overdue =
          _task('1', 'Overdue', due: now.subtract(const Duration(hours: 1)));
      final soon = _task(
        '2',
        'Soon',
        assignedTo: 'me',
        due: now.add(const Duration(hours: 1)),
      );
      final plain = _task('3', 'Plain');
      final theirs = _task('4', 'Theirs', assignedTo: 'you');
      final done = _task('5', 'Done', status: TaskStatus.completed);
      final justTicked = _task('6', 'Ticked');

      final list = myOpenTasks(
        [plain, soon, theirs, done, justTicked, overdue],
        'me',
        {'6': TaskStatus.completed},
        now,
      );
      expect(list.map((t) => t.id), ['1', '2', '3']);
    });
  });

  group('shift mode screen', () {
    final venue = Venue(
      id: 'venue-1',
      organizationId: 'org',
      name: 'Venue',
      createdAt: DateTime(2026),
    );

    testWidgets(
        'shows my shift, clock state and tasks; ticking a task completes it',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      final real = DateTime.now();
      final tasks = _Tasks([
        _task('t1', 'Restock ice'),
        _task('t2', 'Not mine', assignedTo: 'someone-else'),
      ]);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeVenueProvider.overrideWith((ref) => venue),
            currentUserIdProvider.overrideWithValue('me'),
            schedulesRepositoryProvider.overrideWithValue(
              _Schedules([
                _shift(
                  's1',
                  'me',
                  real.subtract(const Duration(hours: 1)),
                  real.add(const Duration(hours: 3)),
                ),
              ]),
            ),
            tasksRepositoryProvider.overrideWithValue(tasks),
            activeTimeEntryProvider.overrideWith((ref, id) async => null),
            unreadNotificationsCountProvider.overrideWithValue(2),
            offlineQueueStoreProvider.overrideWithValue(_Store()),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const ShiftModeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('On shift'), findsOneWidget);
      expect(find.text('Server'), findsOneWidget);
      expect(find.text('Clocked out'), findsOneWidget);
      expect(find.text('Clock in'), findsOneWidget);
      expect(find.text('Restock ice'), findsOneWidget);
      expect(find.text('Not mine'), findsNothing);
      expect(find.text('2'), findsOneWidget); // unread badge

      await tester.tap(find.text('Restock ice'));
      await tester.pumpAndSettle();

      expect(tasks.done, ['t1']);
    });

    testWidgets('with no shift or tasks it shows calm empty states',
        (tester) async {
      tester.view.physicalSize = const Size(800, 1800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeVenueProvider.overrideWith((ref) => venue),
            currentUserIdProvider.overrideWithValue('me'),
            schedulesRepositoryProvider.overrideWithValue(_Schedules(const [])),
            tasksRepositoryProvider.overrideWithValue(_Tasks(const [])),
            activeTimeEntryProvider.overrideWith((ref, id) async => null),
            unreadNotificationsCountProvider.overrideWithValue(0),
            offlineQueueStoreProvider.overrideWithValue(_Store()),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: const ShiftModeScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('No upcoming shifts scheduled.'), findsOneWidget);
      expect(find.text("You're all caught up."), findsOneWidget);
    });
  });
}
