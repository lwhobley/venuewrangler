import 'dart:convert';
import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'pending_mutation.dart';

/// Legacy file-backed store retained for focused tests and secure-store migration recovery.
/// Production uses [SecureStorageOfflineQueueStore] so incident narratives and queued payloads
/// are not persisted as plaintext JSON.
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

/// Encrypted queue store used in production on native and web. On native it can import the
/// previous plaintext file/backup once; successful secure persistence precedes deleting those
/// copies. Values are cleared with the rest of secure session storage on sign-out.
class SecureStorageOfflineQueueStore implements OfflineQueueStore {
  const SecureStorageOfflineQueueStore({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
    this.key = 'offline_mutation_queue',
    this.migrateLegacyFile = false,
  }) : _storage = storage;

  final FlutterSecureStorage _storage;
  final String key;
  final bool migrateLegacyFile;

  @override
  Future<List<PendingMutation>> loadAll() async {
    final raw = await _storage.read(key: key);
    if (raw == null || raw.trim().isEmpty) {
      if (migrateLegacyFile) return _importLegacyFile();
      return const [];
    }
    final queue = _decode(raw, tolerant: !migrateLegacyFile);
    if (migrateLegacyFile) await _removeLegacyFiles();
    return queue;
  }

  List<PendingMutation> _decode(String raw, {bool tolerant = true}) {
    try {
      final decoded = jsonDecode(raw) as List<dynamic>;
      return decoded
          .map(
            (entry) => PendingMutation.fromJson(entry as Map<String, dynamic>),
          )
          .toList(growable: false);
    } on FormatException {
      if (!tolerant) rethrow;
      // A blob the browser left half-written is unrecoverable; starting empty is better than
      // throwing from the controller's load and leaving offline writes permanently broken.
      return const [];
    } on TypeError {
      if (!tolerant) rethrow;
      return const [];
    }
  }

  Future<List<PendingMutation>> _importLegacyFile() async {
    final dir = await getApplicationSupportDirectory();
    final file = File('${dir.path}/offline_mutation_queue.json');
    final backup = File('${file.path}.bak');
    File? source = await file.exists() ? file : null;
    source ??= await backup.exists() ? backup : null;
    if (source == null) return const [];

    List<PendingMutation> queue;
    try {
      queue = _decode(await source.readAsString(), tolerant: false);
    } on FormatException {
      if (source.path == backup.path || !await backup.exists()) rethrow;
      queue = _decode(await backup.readAsString(), tolerant: false);
    } on TypeError {
      if (source.path == backup.path || !await backup.exists()) rethrow;
      queue = _decode(await backup.readAsString(), tolerant: false);
    }
    // Persist encrypted data before removing either plaintext copy. If secure storage fails,
    // leave the recoverable legacy files untouched and surface the error to the caller.
    await saveAll(queue);
    await _removeLegacyFiles();
    return queue;
  }

  Future<void> _removeLegacyFiles() async {
    final dir = await getApplicationSupportDirectory();
    for (final suffix in ['', '.bak', '.tmp']) {
      final file = File('${dir.path}/offline_mutation_queue.json$suffix');
      if (await file.exists()) await file.delete();
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
