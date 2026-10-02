import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/billing_repository.dart';
import '../domain/subscription.dart';

final billingRepositoryProvider = Provider<BillingRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseBillingRepository(client);
});

final subscriptionForOrgProvider =
    FutureProvider.autoDispose.family<Subscription?, String>((ref, organizationId) {
  return ref.watch(billingRepositoryProvider).fetchSubscription(organizationId);
});
