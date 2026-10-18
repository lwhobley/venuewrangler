import '../../../core/storage/secure_session_storage.dart';

/// Bump when the disclosure wording changes materially, so people are asked again.
const aiConsentVersion = 'v1';

/// Whether a user has acknowledged the AI processor disclosure on this device.
abstract interface class AiConsentStore {
  Future<bool> hasConsent(String userId);

  Future<void> grant(String userId);
}

/// Keeps the acknowledgement in secure storage, keyed by user so a second person on a shared
/// device is asked too. Note [SecureSessionStorage.clearAll] runs on sign-out and removes it,
/// so the notice appears again after signing back in.
class SecureAiConsentStore implements AiConsentStore {
  const SecureAiConsentStore([
    this._storage = const SecureSessionStorage(),
  ]);

  final SecureSessionStorage _storage;

  String _key(String userId) => 'ai_processor_consent.$userId';

  @override
  Future<bool> hasConsent(String userId) async =>
      await _storage.read(_key(userId)) == aiConsentVersion;

  @override
  Future<void> grant(String userId) =>
      _storage.write(_key(userId), aiConsentVersion);
}
