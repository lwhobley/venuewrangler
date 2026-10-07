import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';

void main() {
  PendingMutation mutation(String id) => PendingMutation(
        id: id,
        kind: 'k',
        payload: {'value': id},
        createdAt: DateTime.utc(2026, 10, 7),
        userId: 'user-a',
      );

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('an empty store loads as an empty queue', () async {
    expect(await const SecureStorageOfflineQueueStore().loadAll(), isEmpty);
  });

  test('saved mutations round-trip through storage in order', () async {
    const store = SecureStorageOfflineQueueStore();
    await store.saveAll([mutation('a'), mutation('b')]);

    final loaded = await const SecureStorageOfflineQueueStore().loadAll();

    expect(loaded.map((m) => m.id), ['a', 'b']);
    expect(loaded.first.userId, 'user-a');
    expect(loaded.first.payload, {'value': 'a'});
  });

  test('saving an empty list clears the queue', () async {
    const store = SecureStorageOfflineQueueStore();
    await store.saveAll([mutation('a')]);
    await store.saveAll(const []);

    expect(await store.loadAll(), isEmpty);
  });

  test('a corrupt stored blob loads as empty instead of throwing', () async {
    FlutterSecureStorage.setMockInitialValues(
      {'offline_mutation_queue': '[{"id": '},
    );

    expect(await const SecureStorageOfflineQueueStore().loadAll(), isEmpty);
  });
}
