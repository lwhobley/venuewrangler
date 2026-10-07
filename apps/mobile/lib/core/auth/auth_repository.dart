import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:supabase_flutter/supabase_flutter.dart';

/// Where the password-reset email sends the user: the app's custom URL scheme (registered in
/// AndroidManifest.xml and Info.plist). supabase_flutter picks the link up, exchanges its code
/// for a recovery session (PKCE — so it must be opened on the device that asked for it) and
/// emits AuthChangeEvent.passwordRecovery. This URL must be in the Supabase project's
/// Auth → URL Configuration → Redirect URLs allow-list.
const kPasswordResetRedirect = 'venuewrangler://reset-password';

/// Where the sign-up confirmation email sends a web user: back into the Flutter web app at
/// /app/ on whatever origin they signed up from, so supabase_flutter can exchange the PKCE
/// code (its verifier lives in this browser's storage) and the pending workspace gets created
/// straight away. Native sign-ups return `null` and fall back to the project's Site URL — the
/// link still confirms the address server-side, and the user then signs in in the app. The web
/// URL must be in the Supabase project's Auth → URL Configuration → Redirect URLs allow-list.
String? signUpEmailRedirect() => kIsWeb ? '${Uri.base.origin}/app/' : null;

/// Where the password-reset email sends the user. Native builds use the app's custom scheme
/// ([kPasswordResetRedirect]); a custom scheme means nothing in a browser, so on web the link
/// returns to the Flutter web app at /app/ on the origin the request was made from (the PKCE
/// verifier lives in this browser's storage, so it has to open here). Same allow-list note as
/// [signUpEmailRedirect].
String passwordResetRedirect() =>
    kIsWeb ? '${Uri.base.origin}/app/' : kPasswordResetRedirect;

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

  /// Returns `true` if signing up also returned a usable session (email confirmation is off
  /// for this project), `false` if the account needs email confirmation before it can sign in.
  /// [data] is stashed as Supabase Auth user metadata and comes back on `User.userMetadata` —
  /// used by [pendingWorkspaceCreationTriggerProvider] to finish creating a workspace once a
  /// session exists, whether that's immediately or after the user confirms their email later.
  Future<bool> signUpWithPassword({
    required String email,
    required String password,
    Map<String, dynamic>? data,
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
  Future<bool> signUpWithPassword({
    required String email,
    required String password,
    Map<String, dynamic>? data,
  }) async {
    final response = await _client.auth.signUp(
      email: email,
      password: password,
      data: data,
      emailRedirectTo: signUpEmailRedirect(),
    );
    return response.session != null;
  }

  @override
  Future<void> sendPasswordResetEmail(String email) async {
    await _client.auth.resetPasswordForEmail(
      email,
      redirectTo: passwordResetRedirect(),
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
