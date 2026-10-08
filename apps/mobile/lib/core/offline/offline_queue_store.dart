import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
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
  FileOfflineQueueStore({
    this.fileName = 'offline_mutation_queue.json',
    this.directory,
  });

  final String fileName;
  final Directory? directory;

  Future<File> _file() async {
    final dir = directory ?? await getApplicationSupportDirectory();
    return File('${dir.path}/$fileName');
  }

  @override
  Future<List<PendingMutation>> loadAll() async {
    final file = await _file();
    final backup = File('${file.path}.bak');
    if (!await file.exists() && !await backup.exists()) return const [];

    Future<List<PendingMutation>> decode(File source) async {
      final raw = await source.readAsString();
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (entry) => PendingMutation.fromJson(
              entry as Map<String, dynamic>,
            ),
          )
          .toList(growable: false);
    }

    if (await file.exists()) {
      try {
        return await decode(file);
      } on FormatException {
        if (!await backup.exists()) rethrow;
      } on TypeError {
        if (!await backup.exists()) rethrow;
      }
    }
    // A process kill between replacing the original and renaming the new file
    // leaves the previous complete queue here. Never silently discard it.
    return decode(backup);
  }

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    final file = await _file();
    final temp = File('${file.path}.tmp');
    final backup = File('${file.path}.bak');
    final encoded = jsonEncode(mutations.map((m) => m.toJson()).toList());
    await temp.writeAsString(encoded, flush: true);
    if (await file.exists()) {
      await file.copy(backup.path);
      await file.delete();
    }
    await temp.rename(file.path);
  }
}

/// Browser-backed queue, used instead of [FileOfflineQueueStore] on web: `path_provider` has no
/// web implementation and there is no filesystem, so the file store throws during
/// initialization and no queued action could ever be saved or replayed. flutter_secure_storage
/// is already a dependency and supports web (encrypted values in `localStorage`), so this adds
/// no new plugin to the native builds. Cleared along with every other secure-storage value on
/// sign-out (see core/auth/sign_out_service.dart).
class SecureStorageOfflineQueueStore implements OfflineQueueStore {
  const SecureStorageOfflineQueueStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
    this.key = 'offline_mutation_queue',
  }) : _storage = storage;

  final FlutterSecureStorage _storage;
  final String key;

  @override
  Future<List<PendingMutation>> loadAll() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.trim().isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (entry) => PendingMutation.fromJson(entry as Map<String, dynamic>),
          )
          .toList(growable: false);
    } on FormatException {
      // A blob the browser left half-written is unrecoverable; starting empty is better than
      // throwing from the controller's load and leaving offline writes permanently broken.
      return const [];
    }
  }

  @override
  Future<void> saveAll(List<PendingMutation> mutations) async {
    await _storage.write(
      key: key,
      value: jsonEncode(mutations.map((m) => m.toJson()).toList()),
    );
  }
}
