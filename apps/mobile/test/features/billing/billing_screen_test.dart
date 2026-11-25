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
  _FakeBillingRepository({
    this.status = 'past_due',
    this.cancelAtPeriodEnd = false,
    this.currentPeriodEnd,
  });

  final String status;
  final bool cancelAtPeriodEnd;
  final DateTime? currentPeriodEnd;

  @override
  Future<Subscription?> fetchSubscription(String organizationId) async =>
      Subscription(
        organizationId: organizationId,
        status: status,
        cancelAtPeriodEnd: cancelAtPeriodEnd,
        currentPeriodEnd: currentPeriodEnd,
      );
}

Future<void> _pump(WidgetTester tester, BillingRepository repo) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        currentUserIdProvider.overrideWith((ref) => 'user-1'),
        billingRepositoryProvider.overrideWithValue(repo),
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

  test('subscriptionPeriodLabel never says "Renews" for an ending subscription',
      () {
    Subscription sub(String status, {bool cancel = false}) => Subscription(
          organizationId: 'org-1',
          status: status,
          cancelAtPeriodEnd: cancel,
        );
    expect(subscriptionPeriodLabel(sub('active'), 'Dec 1'), 'Renews on Dec 1');
    expect(
      subscriptionPeriodLabel(sub('trialing'), 'Dec 1'),
      'Renews on Dec 1',
    );
    expect(
      subscriptionPeriodLabel(sub('active', cancel: true), 'Dec 1'),
      'Ends on Dec 1',
    );
    expect(subscriptionPeriodLabel(sub('canceled'), 'Dec 1'), 'Canceled');
    expect(
      subscriptionPeriodLabel(sub('canceled', cancel: true), 'Dec 1'),
      'Canceled',
    );
    expect(subscriptionPeriodLabel(sub('canceled'), null), 'Canceled');
    expect(
      subscriptionPeriodLabel(sub('incomplete_expired'), 'Dec 1'),
      'Canceled',
    );
    expect(
      subscriptionPeriodLabel(sub('past_due'), 'Dec 1'),
      'Current period ends on Dec 1',
    );
    expect(subscriptionPeriodLabel(sub('active'), null), isNull);
  });

  testWidgets('a canceled subscription is not shown as renewing',
      (tester) async {
    await _pump(
      tester,
      _FakeBillingRepository(
        status: 'canceled',
        currentPeriodEnd: DateTime.utc(2026, 12, 1, 12),
      ),
    );
    expect(find.text('Canceled'), findsOneWidget);
    expect(find.textContaining('Renews'), findsNothing);
  });

  testWidgets('a subscription set to cancel shows when it ends',
      (tester) async {
    await _pump(
      tester,
      _FakeBillingRepository(
        status: 'active',
        cancelAtPeriodEnd: true,
        currentPeriodEnd: DateTime.utc(2026, 12, 1, 12),
      ),
    );
    expect(find.textContaining('Ends on'), findsOneWidget);
    expect(find.textContaining('Renews'), findsNothing);
  });
}
