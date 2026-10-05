import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// [LocalStorage] backend that keeps the Supabase session (refresh token)
/// in encrypted storage instead of SharedPreferences/NSUserDefaults XML.
///
/// Wired in app/bootstrap.dart via
/// `FlutterAuthClientOptions(localStorage: SecureLocalStorage())`.
class SecureLocalStorage extends LocalStorage {
  SecureLocalStorage({
    FlutterSecureStorage storage = const FlutterSecureStorage(),
    this.persistSessionKey = 'supabase_persist_session',
  }) : _storage = storage;

  final FlutterSecureStorage _storage;
  final String persistSessionKey;

  @override
  Future<void> initialize() async {}

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
