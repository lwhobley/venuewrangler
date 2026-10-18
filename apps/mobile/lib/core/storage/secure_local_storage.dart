import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_secure_storage.dart';

/// [LocalStorage] backend that keeps the Supabase session (refresh token)
/// in encrypted storage instead of SharedPreferences/NSUserDefaults XML.
///
/// Wired in app/bootstrap.dart via
/// `FlutterAuthClientOptions(localStorage: SecureLocalStorage())`.
class SecureLocalStorage extends LocalStorage {
  SecureLocalStorage({
    FlutterSecureStorage storage = const AppSecureStorage(),
    this.persistSessionKey = 'supabase_persist_session',
    Future<bool> Function()? firstRunWipe,
  })  : _storage = storage,
        _firstRunWipe = firstRunWipe ?? wipeKeychainOnFirstInstallRun;

  final FlutterSecureStorage _storage;
  final String persistSessionKey;
  final Future<bool> Function() _firstRunWipe;

  /// Runs before Supabase reads the stored session, so a Keychain left behind by a previous
  /// install (iOS keeps it across uninstall) is cleared before it can resurrect a session.
  @override
  Future<void> initialize() async {
    await _firstRunWipe();
  }

  @override
  Future<bool> hasAccessToken() async {
    final value = await _storage.read(key: persistSessionKey);
    return value != null && value.isNotEmpty;
  }

  @override
  Future<String?> accessToken() => _storage.read(key: persistSessionKey);

  @override
  Future<void> removePersistedSession() =>
      _storage.delete(key: persistSessionKey);

  @override
  Future<void> persistSession(String persistSessionString) =>
      _storage.write(key: persistSessionKey, value: persistSessionString);
}
