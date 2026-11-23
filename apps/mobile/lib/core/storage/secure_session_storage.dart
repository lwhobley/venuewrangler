import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'app_secure_storage.dart';

const registeredPushTokenStorageKey = 'registered_push_token';
const pendingPushTokenRevocationStorageKey = 'pending_push_token_revocation';
const pushInstallationSecretStorageKey = 'push_installation_secret';

/// Encrypted offline mutation queue. It holds several users' unsynced writes on a shared device,
/// so sign-out clears only the signed-out user's entries and this blob is kept across
/// [SecureSessionStorage.clearAll].
const offlineMutationQueueStorageKey = 'offline_mutation_queue';

/// Prefix for per-user floor-plan drafts (`floor_draft_${userId}_$planId`). Like the offline
/// queue, drafts for other accounts on a shared device survive [SecureSessionStorage.clearAll].
const floorDraftStorageKeyPrefix = 'floor_draft_';

/// Thin wrapper over `flutter_secure_storage` for session-sensitive values, including
/// the Supabase session itself (wired as the auth local-storage backend in
/// app/bootstrap.dart — SharedPreferences/NSUserDefaults must never hold the refresh
/// token). Use this for things like a cached device-attestation key id (Phase 3) or a
/// correlation id tied to an in-flight privileged request.
class SecureSessionStorage {
  const SecureSessionStorage([this._storage = const AppSecureStorage()]);

  final FlutterSecureStorage _storage;

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<void> delete(String key) => _storage.delete(key: key);

  /// Clear user-scoped data while retaining device and appearance settings, the offline
  /// queue (already pruned of the signed-out user's entries), and other users' floor drafts.
  ///
  /// When [signingOutUserId] is set, that account's `floor_draft_*` keys are dropped; every
  /// other account's drafts are kept. When it is null (owner unknown), all floor drafts are
  /// retained rather than wiping every account on the device.
  Future<void> clearAll({String? signingOutUserId}) async {
    const deviceKeys = [
      'theme_mode',
      'app_attest.device_id',
      'app_attest.key_id',
      pendingPushTokenRevocationStorageKey,
      pushInstallationSecretStorageKey,
      offlineMutationQueueStorageKey,
    ];
    final retained = <String, String>{};
    for (final key in deviceKeys) {
      final value = await _storage.read(key: key);
      if (value != null) retained[key] = value;
    }
    final signedOutDraftPrefix = signingOutUserId == null
        ? null
        : '$floorDraftStorageKeyPrefix${signingOutUserId}_';
    final all = await _storage.readAll();
    for (final entry in all.entries) {
      if (!entry.key.startsWith(floorDraftStorageKeyPrefix)) continue;
      if (signedOutDraftPrefix != null &&
          entry.key.startsWith(signedOutDraftPrefix)) {
        continue;
      }
      retained[entry.key] = entry.value;
    }
    await _storage.deleteAll();
    for (final entry in retained.entries) {
      await _storage.write(key: entry.key, value: entry.value);
    }
  }
}
