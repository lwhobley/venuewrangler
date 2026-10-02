import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/subscription.dart';

/// Calls the `stripe-create-checkout`/`stripe-create-portal` Edge Functions (hosted Stripe
/// URLs only — this app never embeds a payment form or sees Stripe secret material, per
/// features/billing/README.md) and reads `subscriptions` directly (RLS-gated to org
/// owners/admins, see supabase/migrations/20261002130000_subscriptions_schema.sql).
abstract interface class BillingRepository {
  /// Returns `null` if the organization has never checked out (no row exists yet) or the
  /// caller isn't an org owner/admin (RLS hides the row rather than erroring).
  Future<Subscription?> fetchSubscription(String organizationId);

  /// Returns a hosted Stripe Checkout URL to open in an external browser.
  Future<String> createCheckoutUrl(String organizationId);

  /// Returns a hosted Stripe Billing Portal URL to open in an external browser.
  Future<String> createPortalUrl(String organizationId);
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

  @override
  Future<String> createCheckoutUrl(String organizationId) {
    return _invokeForUrl('stripe-create-checkout', organizationId);
  }

  @override
  Future<String> createPortalUrl(String organizationId) {
    return _invokeForUrl('stripe-create-portal', organizationId);
  }

  Future<String> _invokeForUrl(String functionName, String organizationId) async {
    try {
      final response = await _client.functions.invoke(
        functionName,
        body: {'organization_id': organizationId},
      );
      final url = (response.data as Map?)?['url'] as String?;
      if (url == null) {
        throw const UnknownError('Billing is temporarily unavailable.');
      }
      return url;
    } on FunctionException catch (error) {
      throw _mapFunctionException(error);
    }
  }

  AppError _mapFunctionException(FunctionException error) {
    final details = error.details;
    final code = details is Map ? details['error'] as String? : null;

    return switch (code) {
      'not_an_organization_admin' => const PermissionDeniedError(
          'Only an organization owner or admin can manage billing.',
        ),
      'no_stripe_customer' => const UnknownError(
          'Subscribe first before managing billing.',
        ),
      'billing_not_configured' => const UnknownError(
          'Billing is not configured yet. Please try again later.',
        ),
      'invalid_or_expired_session' => const AuthError('Your session has expired. Please sign in again.'),
      _ => error.status >= 500
          ? const UnknownError('Billing is temporarily unavailable.')
          : const UnknownError('Something went wrong. Please try again.'),
    };
  }
}
