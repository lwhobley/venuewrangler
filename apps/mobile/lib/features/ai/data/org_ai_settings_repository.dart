import 'package:supabase_flutter/supabase_flutter.dart';

/// The organization-wide AI switch (`organizations.ai_enabled`, enforced by the `ai-assistant`
/// Edge Function, which answers `ai_disabled_for_org` when it is off).
abstract interface class OrgAiSettingsRepository {
  Future<bool> fetchEnabled(String organizationId);

  /// `public.set_org_ai_enabled`: owner/admin only (`42501` otherwise).
  Future<void> setEnabled(String organizationId, bool enabled);
}

class SupabaseOrgAiSettingsRepository implements OrgAiSettingsRepository {
  const SupabaseOrgAiSettingsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<bool> fetchEnabled(String organizationId) async {
    final row = await _client
        .from('organizations')
        .select('ai_enabled')
        .eq('id', organizationId)
        .single();
    return row['ai_enabled'] as bool? ?? false;
  }

  @override
  Future<void> setEnabled(String organizationId, bool enabled) async {
    await _client.rpc(
      'set_org_ai_enabled',
      params: {'p_organization_id': organizationId, 'p_enabled': enabled},
    );
  }
}
