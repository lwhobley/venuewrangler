import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/org_ai_settings_repository.dart';

final orgAiSettingsRepositoryProvider =
    Provider<OrgAiSettingsRepository>((ref) {
  return SupabaseOrgAiSettingsRepository(ref.watch(supabaseClientProvider));
});

/// Whether AI features are on for the organization.
final orgAiEnabledProvider =
    FutureProvider.autoDispose.family<bool, String>((ref, organizationId) {
  return ref
      .watch(orgAiSettingsRepositoryProvider)
      .fetchEnabled(organizationId);
});
