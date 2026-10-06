import 'package:supabase_flutter/supabase_flutter.dart';

/// Where the password-reset email sends the user: the app's custom URL scheme (registered in
/// AndroidManifest.xml and Info.plist). supabase_flutter picks the link up, exchanges its code
/// for a recovery session (PKCE — so it must be opened on the device that asked for it) and
/// emits AuthChangeEvent.passwordRecovery. This URL must be in the Supabase project's
/// Auth → URL Configuration → Redirect URLs allow-list.
const kPasswordResetRedirect = 'venuewrangler://reset-password';

/// The project's password policy (Supabase Auth: lower, upper, digit and symbol, 8+ chars),
/// checked client-side so the user sees what's wrong before a round trip.
String? passwordPolicyProblem(String password) {
  if (password.length < 8) return 'Use at least 8 characters';
  if (!RegExp('[a-z]').hasMatch(password)) return 'Add a lowercase letter';
  if (!RegExp('[A-Z]').hasMatch(password)) return 'Add an uppercase letter';
  if (!RegExp('[0-9]').hasMatch(password)) return 'Add a number';
  if (!RegExp(r'[^A-Za-z0-9]').hasMatch(password)) return 'Add a symbol';
  return null;
}

/// UI/controllers depend on this interface, never on `SupabaseClient` directly — per the
/// migration plan's requirement that "UI does not directly call Supabase clients." The only
/// implementation today is [SupabaseAuthRepository]; a fake implementation backs widget
/// tests.
abstract interface class AuthRepository {
  Session? get currentSession;

  Future<void> signInWithPassword({
    required String email,
    required String password,
  });

  Future<void> signUpWithPassword({
    required String email,
    required String password,
  });

  /// Emails a reset link that opens the app ([kPasswordResetRedirect]); tapping it signs the
  /// user in with a recovery session and the app asks for a new password.
  Future<void> sendPasswordResetEmail(String email);

  /// Sets a new password for the signed-in (or recovery-session) user.
  Future<void> updatePassword(String newPassword);

  Future<void> signOut();
}

class SupabaseAuthRepository implements AuthRepository {
  const SupabaseAuthRepository(this._client);

  final SupabaseClient _client;

  @override
  Session? get currentSession => _client.auth.currentSession;

  @override
  Future<void> signInWithPassword({
    required String email,
    required String password,
  }) async {
    await _client.auth.signInWithPassword(email: email, password: password);
  }

  @override
  Future<void> signUpWithPassword({
    required String email,
    required String password,
  }) async {
    await _client.auth.signUp(email: email, password: password);
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    await _client.auth.resetPasswordForEmail(
      email,
      redirectTo: kPasswordResetRedirect,
    );
  }

  @override
  Future<void> updatePassword(String newPassword) async {
    await _client.auth.updateUser(UserAttributes(password: newPassword));
  }

  @override
  Future<void> signOut() async {
    await _client.auth.signOut();
  }
}
