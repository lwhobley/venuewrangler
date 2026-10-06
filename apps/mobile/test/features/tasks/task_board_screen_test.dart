import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/core/theme/app_theme.dart';
import 'package:venuewrangler_mobile/features/tasks/application/tasks_providers.dart';
import 'package:venuewrangler_mobile/features/tasks/data/tasks_repository.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/operational_task.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/task_board.dart';
import 'package:venuewrangler_mobile/features/tasks/presentation/task_board_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/workforce/application/workforce_providers.dart';

class _Store implements OfflineQueueStore {
  List<PendingMutation> saved = const [];

  @override
  Future<List<PendingMutation>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    saved = mutations;
  }
}

class _Repo implements TasksRepository {
  _Repo(this.tasks);

  List<OperationalTask> tasks;
  final moves = <(String, TaskStatus)>[];
  String? createdTitle;

  @override
  Future<List<OperationalTask>> fetchTasksForVenue(String venueId) async =>
      tasks;

  @override
  Future<void> updateStatus(String taskId, TaskStatus status) async {
    moves.add((taskId, status));
  }

  @override
  Future<void> createTask({
    required String venueId,
    required String title,
    String? description,
    DateTime? dueAt,
    String? assignedTo,
  }) async {
    createdTitle = title;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

OperationalTask _task(
  String id,
  String title,
  TaskStatus status, {
  DateTime? due,
  DateTime? created,
}) =>
    OperationalTask(
      id: id,
      venueId: 'venue-1',
      organizationId: 'org',
      title: title,
      status: status,
      dueAt: due,
      createdAt: created ?? DateTime(2026),
      updatedAt: DateTime(2026),
    );

void main() {
  group('board grouping', () {
    test('groups by status, due dates first, cancelled hidden', () {
      final soon = _task(
        'a',
        'Soon',
        TaskStatus.open,
        due: DateTime(2026, 1, 2),
      );
      final later = _task(
        'b',
        'Later',
        TaskStatus.open,
        due: DateTime(2026, 1, 9),
      );
      final none = _task('c', 'None', TaskStatus.open);
      final done = _task('d', 'Done', TaskStatus.completed);
      final gone = _task('e', 'Gone', TaskStatus.cancelled);

      final lanes = groupIntoLanes([none, later, soon, done, gone], {});
      expect(lanes[TaskLane.open]!.map((t) => t.id), ['a', 'b', 'c']);
      expect(lanes[TaskLane.completed]!.map((t) => t.id), ['d']);
      expect(lanes.values.expand((l) => l).any((t) => t.id == 'e'), isFalse);
    });

    test('a queued status change moves the task to its new lane', () {
      final t = _task('a', 'A', TaskStatus.open);
      final lanes = groupIntoLanes([t], {'a': TaskStatus.inProgress});
      expect(lanes[TaskLane.inProgress]!.single.id, 'a');
      expect(lanes[TaskLane.open], isEmpty);
    });

    test('overdue only applies to unfinished tasks', () {
      final t = _task('a', 'A', TaskStatus.open, due: DateTime(2020));
      final now = DateTime(2026);
      expect(isOverdue(t, TaskStatus.open, now), isTrue);
      expect(isOverdue(t, TaskStatus.completed, now), isFalse);
    });
  });

  group('board screen', () {
    final venue = Venue(
      id: 'venue-1',
      organizationId: 'org',
      name: 'Venue',
      createdAt: DateTime(2026),
    );

    Future<_Repo> pump(WidgetTester tester, List<OperationalTask> tasks) async {
      tester.view.physicalSize = const Size(1000, 1200);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final repo = _Repo(tasks);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeVenueProvider.overrideWith((ref) => venue),
            tasksRepositoryProvider.overrideWithValue(repo),
            offlineQueueStoreProvider.overrideWithValue(_Store()),
            rosterForVenueProvider.overrideWith((ref, id) async => const []),
          ],
          child: MaterialApp(
            theme: AppTheme.dark(),
            home: const TaskBoardScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      return repo;
    }

    testWidgets('shows lanes and moves a card by dragging it to another lane',
        (tester) async {
      final repo = await pump(tester, [
        _task('t1', 'Restock ice', TaskStatus.open),
        _task('t2', 'Mop floor', TaskStatus.completed),
      ]);

      expect(find.text('To do  ·  1'), findsOneWidget);
      expect(find.text('Done  ·  1'), findsOneWidget);

      final gesture =
          await tester.startGesture(tester.getCenter(find.text('Restock ice')));
      await tester.pump(const Duration(milliseconds: 700));
      await gesture.moveTo(tester.getCenter(find.text('In progress  ·  0')));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(repo.moves, [('t1', TaskStatus.inProgress)]);
    });

    testWidgets('tapping a card offers a button-based way to move it',
        (tester) async {
      final repo = await pump(tester, [
        _task('t1', 'Restock ice', TaskStatus.open),
      ]);

      await tester.tap(find.text('Restock ice'));
      await tester.pumpAndSettle();
      await tester.tap(
        find.descendant(
          of: find.byType(SegmentedButton<TaskStatus>),
          matching: find.text('Done'),
        ),
      );
      await tester.pumpAndSettle();

      expect(repo.moves, [('t1', TaskStatus.completed)]);
    });

    testWidgets('creating a task sends its title', (tester) async {
      final repo = await pump(tester, const []);

      await tester.tap(find.text('New task'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField).first, 'Polish glasses');
      await tester.tap(find.widgetWithText(FilledButton, 'Create'));
      await tester.pumpAndSettle();

      expect(repo.createdTitle, 'Polish glasses');
    });
  });
}
