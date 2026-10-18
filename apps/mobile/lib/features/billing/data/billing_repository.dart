import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/subscription.dart';

/// Reads `subscriptions` directly (RLS-gated to org owners/admins, see
/// supabase/migrations/20261002130000_subscriptions_schema.sql). The app never starts a
/// checkout or opens the billing portal itself; those Edge Functions are not called from here.
abstract interface class BillingRepository {
  /// Returns `null` if the organization has never checked out (no row exists yet) or the
  /// caller isn't an org owner/admin (RLS hides the row rather than erroring).
  Future<Subscription?> fetchSubscription(String organizationId);
}

class SupabaseBillingRepository implements BillingRepository {
  const SupabaseBillingRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<Subscription?> fetchSubscription(String organizationId) async {
    final row = await _client
        .from('subscriptions')
        .select()
        .eq('organization_id', organizationId)
        .maybeSingle();

    return row == null ? null : Subscription.fromJson(row);
  }
}
