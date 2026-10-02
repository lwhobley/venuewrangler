import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';

import 'pending_mutation.dart';

/// Persists the pending-mutation queue across app restarts. Modeled on the same shape as the
/// legacy Expo app's `lib/offline-inventory-queue.ts` (a JSON array written to a local file),
/// per the Phase 0 discovery in docs/migration/flutter-supabase-rebuild-plan.md — a plain
/// JSON file is enough for a queue that is expected to hold a handful to a few dozen pending
/// items, not a large dataset.
abstract interface class OfflineQueueStore {
  Future<List<PendingMutation>> loadAll();

  Future<void> saveAll(List<PendingMutation> mutations);
}

class FileOfflineQueueStore implements OfflineQueueStore {
  FileOfflineQueueStore({this.fileName = 'offline_mutation_queue.json'});

  final String fileName;

  Future<File> _file() async {
    final dir = await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }

  @override
  Future<List<PendingMutation>> loadAll() async {
    final file = await _file();
    if (!await file.exists()) return const [];

    final raw = await file.readAsString();
    if (raw.trim().isEmpty) return const [];

    final decoded = jsonDecode(raw) as List<dynamic>;
    return decoded
        .map((entry) => PendingMutation.fromJson(entry as Map<String, dynamic>))
        .toList(growable: false);
  }

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    final file = await _file();
    final encoded = jsonEncode(mutations.map((m) => m.toJson()).toList());
    await file.writeAsString(encoded);
  }
}
