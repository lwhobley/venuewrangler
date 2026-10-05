import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/profile.dart';

/// Reads/writes the caller's own `profiles` row (see
/// supabase/migrations/20261002000000_foundation_schema.sql's `profiles_select_self`/
/// `profiles_update_self` policies — a user can only ever touch their own profile through
/// this repository).
abstract interface class SettingsRepository {
  Future<Profile> fetchMyProfile(String userId);

  Future<void> updateDisplayName(String userId, String displayName);
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
}
