import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/offline/offline_queue_store.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';

void main() {
  test(
      'file queue restores the previous complete queue after an interrupted replacement',
      () async {
    final directory =
        await Directory.systemTemp.createTemp('offline-queue-test-');
    addTearDown(() => directory.delete(recursive: true));
    final store = FileOfflineQueueStore(directory: directory);
    final mutation = PendingMutation(
      id: 'mutation-1',
      kind: 'task-status',
      payload: const {'status': 'done'},
      createdAt: DateTime.utc(2026, 10, 7),
      userId: 'user-1',
    );
    await store.saveAll([mutation]);

    final file = File('${directory.path}/offline_mutation_queue.json');
    await file.rename('${file.path}.bak');
    await File('${file.path}.tmp').writeAsString('{incomplete');

    final restored = await store.loadAll();
    expect(restored, hasLength(1));
    expect(restored.single.id, mutation.id);
    expect(restored.single.userId, mutation.userId);

    await file.writeAsString('{incomplete');
    expect((await store.loadAll()).single.id, mutation.id);
  });
}
