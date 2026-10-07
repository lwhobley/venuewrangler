import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/billing/application/billing_providers.dart';
import 'package:venuewrangler_mobile/features/billing/data/billing_repository.dart';
import 'package:venuewrangler_mobile/features/billing/domain/subscription.dart';
import 'package:venuewrangler_mobile/features/billing/presentation/billing_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeBillingRepository implements BillingRepository {
  @override
  Future<Subscription?> fetchSubscription(String organizationId) async =>
      Subscription(
        organizationId: organizationId,
        status: 'past_due',
        cancelAtPeriodEnd: false,
      );

  @override
  Future<String> createCheckoutUrl(String organizationId) =>
      throw UnimplementedError();

  @override
  Future<String> createPortalUrl(String organizationId) =>
      throw UnimplementedError();
}

void main() {
  testWidgets(
      'shows the subscription status and no deposit / Stripe Connect setup',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          currentUserIdProvider.overrideWith((ref) => 'user-1'),
          billingRepositoryProvider.overrideWithValue(_FakeBillingRepository()),
          activeVenueProvider.overrideWith(
            (ref) => Venue(
              id: 'venue-1',
              organizationId: 'org-1',
              name: 'Venue One',
              createdAt: DateTime(2026),
            ),
          ),
        ],
        child: const MaterialApp(home: BillingScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('past_due'), findsOneWidget);
    expect(find.textContaining('deposit', findRichText: true), findsNothing);
    expect(find.textContaining('Stripe account'), findsNothing);
  });
}
