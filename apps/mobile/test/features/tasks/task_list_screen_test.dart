import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/tasks/application/tasks_providers.dart';
import 'package:venuewrangler_mobile/features/tasks/data/tasks_repository.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/operational_task.dart';
import 'package:venuewrangler_mobile/features/tasks/presentation/task_list_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeTasksRepository implements TasksRepository {
  _FakeTasksRepository(this.tasks);

  List<OperationalTask> tasks;
  String? lastStatusUpdateTaskId;
  TaskStatus? lastStatusUpdateValue;
  String? lastCreatedTitle;

  @override
  Future<List<OperationalTask>> fetchTasksForVenue(String venueId) async => tasks;

  @override
  Future<void> createTask({
    required String venueId,
    required String title,
    String? assignedTo,
  }) async {
    lastCreatedTitle = title;
  }

  @override
  Future<void> updateStatus(String taskId, TaskStatus status) async {
    lastStatusUpdateTaskId = taskId;
    lastStatusUpdateValue = status;
  }

  @override
  Future<void> deleteTask(String taskId) async {}
}

void main() {
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue One',
    createdAt: DateTime(2026),
  );

  final openTask = OperationalTask(
    id: 'task-1',
    venueId: 'venue-1',
    organizationId: 'org-1',
    title: 'Restock ice',
    status: TaskStatus.open,
    createdAt: DateTime(2026),
  );

  testWidgets('shows an empty state when there are no tasks', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          tasksRepositoryProvider.overrideWithValue(_FakeTasksRepository(const [])),
        ],
        child: const MaterialApp(home: TaskListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No tasks yet.'), findsOneWidget);
  });

  testWidgets('lists tasks and toggling the checkbox updates status', (tester) async {
    final fakeRepo = _FakeTasksRepository([openTask]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          tasksRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: TaskListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Restock ice'), findsOneWidget);

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastStatusUpdateTaskId, 'task-1');
    expect(fakeRepo.lastStatusUpdateValue, TaskStatus.completed);
  });

  testWidgets('creating a task from the dialog calls the repository', (tester) async {
    final fakeRepo = _FakeTasksRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          tasksRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: TaskListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'New task title');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastCreatedTitle, 'New task title');
  });
}
