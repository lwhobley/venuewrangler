import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/features/tasks/application/tasks_providers.dart';
import 'package:venuewrangler_mobile/features/tasks/data/tasks_repository.dart';
import 'package:venuewrangler_mobile/features/tasks/domain/operational_task.dart';
import 'package:venuewrangler_mobile/features/tasks/presentation/task_list_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _InMemoryOfflineQueueStore implements OfflineQueueStore {
  List<PendingMutation> saved = const [];

  @override
  Future<List<PendingMutation>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    saved = mutations;
  }
}

class _FakeTasksRepository implements TasksRepository {
  _FakeTasksRepository(this.tasks);

  List<OperationalTask> tasks;
  String? lastStatusUpdateTaskId;
  TaskStatus? lastStatusUpdateValue;
  String? lastCreatedTitle;

  /// When true, [updateStatus] throws, simulating no connectivity, so the screen falls back
  /// to queuing the change via the offline queue.
  bool simulateOffline = false;

  @override
  Future<List<OperationalTask>> fetchTasksForVenue(String venueId) async =>
      tasks;

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
    if (simulateOffline) {
      throw Exception('network unreachable');
    }
    lastStatusUpdateTaskId = taskId;
    lastStatusUpdateValue = status;
  }

  @override
  Future<bool> updateStatusIfUnchanged(
    String taskId,
    TaskStatus status,
    DateTime expectedUpdatedAt,
  ) async {
    lastStatusUpdateTaskId = taskId;
    lastStatusUpdateValue = status;
    return true;
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
    updatedAt: DateTime(2026),
  );

  List<Override> baseOverrides(_FakeTasksRepository fakeRepo) => [
        activeVenueProvider.overrideWith((ref) => venue),
        tasksRepositoryProvider.overrideWithValue(fakeRepo),
        offlineQueueStoreProvider
            .overrideWithValue(_InMemoryOfflineQueueStore()),
      ];

  testWidgets('shows an empty state when there are no tasks', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(_FakeTasksRepository(const [])),
        child: const MaterialApp(home: TaskListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('No tasks yet.'), findsOneWidget);
  });

  testWidgets('lists tasks and toggling the checkbox updates status online',
      (tester) async {
    final fakeRepo = _FakeTasksRepository([openTask]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(fakeRepo),
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

  testWidgets(
      'toggling while offline queues the change and shows a syncing badge',
      (tester) async {
    final fakeRepo = _FakeTasksRepository([openTask])..simulateOffline = true;

    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(fakeRepo),
        child: const MaterialApp(home: TaskListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byType(CheckboxListTile));
    await tester.pumpAndSettle();

    expect(find.textContaining('Saved offline'), findsOneWidget);
    expect(find.text('Syncing…'), findsOneWidget);
    // The checkbox reflects the queued change optimistically even though the repository
    // call itself failed.
    final checkbox =
        tester.widget<CheckboxListTile>(find.byType(CheckboxListTile));
    expect(checkbox.value, isTrue);
  });

  testWidgets('creating a task from the dialog calls the repository',
      (tester) async {
    final fakeRepo = _FakeTasksRepository([]);

    await tester.pumpWidget(
      ProviderScope(
        overrides: baseOverrides(fakeRepo),
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
