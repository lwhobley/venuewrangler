import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_providers.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/features/checklists/application/checklists_providers.dart';
import 'package:venuewrangler_mobile/features/checklists/data/checklists_repository.dart';
import 'package:venuewrangler_mobile/features/checklists/domain/checklist_template.dart';
import 'package:venuewrangler_mobile/features/checklists/domain/item_result.dart';
import 'package:venuewrangler_mobile/features/checklists/presentation/checklist_completion_screen.dart';

class _InMemoryOfflineQueueStore implements OfflineQueueStore {
  List<PendingMutation> saved = const [];

  @override
  Future<List<PendingMutation>> loadAll() async => saved;

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    saved = mutations;
  }
}

class _FakeChecklistsRepository implements ChecklistsRepository {
  _FakeChecklistsRepository(this.items);

  final List<ChecklistTemplateItem> items;
  List<ItemResult>? lastSubmittedResults;
  bool simulateOffline = false;

  @override
  Future<List<ChecklistTemplate>> fetchTemplatesForVenue(String venueId) async => const [];

  @override
  Future<List<ChecklistTemplateItem>> fetchItemsForTemplate(String templateId) async => items;

  @override
  Future<void> submitCompletion({
    required String completionId,
    required String templateId,
    required List<ItemResult> itemResults,
    String? notes,
  }) async {
    if (simulateOffline) throw Exception('network unreachable');
    lastSubmittedResults = itemResults;
  }
}

void main() {
  final items = [
    const ChecklistTemplateItem(id: 'item-1', templateId: 'template-1', label: 'Unlock door', position: 1),
    const ChecklistTemplateItem(id: 'item-2', templateId: 'template-1', label: 'Turn on lights', position: 2),
  ];

  Widget buildHarness(_FakeChecklistsRepository fakeRepo) {
    final router = GoRouter(
      initialLocation: '/list',
      routes: [
        GoRoute(path: '/list', builder: (context, state) => const Scaffold(body: Text('Back on list'))),
        GoRoute(
          path: '/detail',
          builder: (context, state) => const ChecklistCompletionScreen(templateId: 'template-1'),
        ),
      ],
    );

    return ProviderScope(
      overrides: [
        checklistsRepositoryProvider.overrideWithValue(fakeRepo),
        offlineQueueStoreProvider.overrideWithValue(_InMemoryOfflineQueueStore()),
      ],
      child: MaterialApp.router(routerConfig: router),
    );
  }

  testWidgets('submitting online calls the repository with checked item results and pops back',
      (tester) async {
    final fakeRepo = _FakeChecklistsRepository(items);

    await tester.pumpWidget(buildHarness(fakeRepo));
    await tester.pumpAndSettle();
    // Navigate to the detail route the same way the list screen does.
    final router = GoRouter.of(tester.element(find.byType(Scaffold)));
    router.push('/detail');
    await tester.pumpAndSettle();

    expect(find.text('Unlock door'), findsOneWidget);

    await tester.tap(find.text('Unlock door'));
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastSubmittedResults, isNotNull);
    expect(
      fakeRepo.lastSubmittedResults!.firstWhere((r) => r.itemId == 'item-1').checked,
      isTrue,
    );
    expect(
      fakeRepo.lastSubmittedResults!.firstWhere((r) => r.itemId == 'item-2').checked,
      isFalse,
    );
    expect(find.text('Back on list'), findsOneWidget);
  });

  testWidgets('submitting while offline queues the mutation and pops back', (tester) async {
    final fakeRepo = _FakeChecklistsRepository(items)..simulateOffline = true;

    await tester.pumpWidget(buildHarness(fakeRepo));
    await tester.pumpAndSettle();
    final router = GoRouter.of(tester.element(find.byType(Scaffold)));
    router.push('/detail');
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Submit'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastSubmittedResults, isNull);
    expect(find.textContaining('Saved offline'), findsOneWidget);
    expect(find.text('Back on list'), findsOneWidget);
  });
}
