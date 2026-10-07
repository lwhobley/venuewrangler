import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/profile.dart';

/// Reads/writes the caller's own `profiles` row (see
/// supabase/migrations/20261002000000_foundation_schema.sql's `profiles_select_self`/
/// `profiles_update_self` policies — a user can only ever touch their own profile through
/// this repository).
abstract interface class SettingsRepository {
  Future<Profile> fetchMyProfile(String userId);

  Future<void> updateDisplayName(String userId, String displayName);

  /// Calls `public.request_account_deletion` (supabase/migrations/*_account_deletion.sql) —
  /// personal "delete my account" only, not organization/tenant offboarding. Synchronously
  /// anonymizes/removes everything RLS-governed (profile, memberships, HR data, time
  /// entries preserved anonymized for wage-law retention); the `auth.users` row itself is
  /// deleted asynchronously by a queued Edge Function, since the Auth Admin API has no
  /// SQL-level equivalent — see that migration's header comment.
  ///
  /// Throws a [PostgrestException] with code `42501` if the caller is the sole
  /// `organization_owner` of any organization — they must add another owner first. The
  /// caller is still fully signed in afterward and must sign out themselves
  /// (features/settings calls [signOutAndClearScopedData] right after this succeeds).
  Future<void> deleteAccount({String? reason});
}

class SupabaseSettingsRepository implements SettingsRepository {
  const SupabaseSettingsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Profile> fetchMyProfile(String userId) async {
    final row =
        await _client.from('profiles').select().eq('id', userId).single();
    return Profile.fromJson(row);
  }

  @override
  Future<void> updateDisplayName(String userId, String displayName) async {
    await _client
        .from('profiles')
        .update({'display_name': displayName}).eq('id', userId);
  }

  @override
  Future<void> deleteAccount({String? reason}) async {
    await _client.rpc(
      'request_account_deletion',
      params: {'p_reason': reason},
    );
  }
}
