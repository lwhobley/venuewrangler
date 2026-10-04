import 'package:flutter_secure_storage/flutter_secure_storage.dart';

/// Thin wrapper over `flutter_secure_storage` for session-sensitive values, including
/// the Supabase session itself (wired as the auth local-storage backend in
/// app/bootstrap.dart — SharedPreferences/NSUserDefaults must never hold the refresh
/// token). Use this for things like a cached device-attestation key id (Phase 3) or a
/// correlation id tied to an in-flight privileged request.
class SecureSessionStorage {
  const SecureSessionStorage([this._storage = const FlutterSecureStorage()]);

  final FlutterSecureStorage _storage;

  Future<String?> read(String key) => _storage.read(key: key);

  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);

  Future<void> delete(String key) => _storage.delete(key: key);

  /// Called on sign-out so nothing from the previous session's scope survives into the next
  /// one on a shared device.
  Future<void> clearAll() => _storage.deleteAll();
}
