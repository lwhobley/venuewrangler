import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../venues/application/venues_providers.dart';
import '../application/billing_providers.dart';
import '../domain/subscription.dart';

/// Shows the organization's subscription status. App subscriptions are sold directly to
/// organizations outside the mobile app; no in-app link initiates a digital purchase.
class BillingScreen extends ConsumerWidget {
  const BillingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final organizationId = venue.organizationId;
    final subscriptionAsync =
        ref.watch(subscriptionForOrgProvider(organizationId));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Billing'),
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(subscriptionForOrgProvider(organizationId));
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Text(
              'App subscription',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            subscriptionAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) =>
                  const Text('Could not load subscription status.'),
              data: (subscription) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _StatusCard(subscription: subscription),
                  const SizedBox(height: 12),
                  const Text(
                    'Your organization manages its app subscription through its business account.',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.subscription});

  final Subscription? subscription;

  @override
  Widget build(BuildContext context) {
    final status = subscription?.status ?? 'none';
    final end = subscription?.currentPeriodEnd?.toLocal();
    final endLabel = end == null
        ? null
        : MaterialLocalizations.of(context).formatMediumDate(end);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(status, style: Theme.of(context).textTheme.headlineSmall),
            if (endLabel != null) ...[
              const SizedBox(height: 8),
              Text(
                subscription!.cancelAtPeriodEnd
                    ? 'Cancels on $endLabel'
                    : 'Renews on $endLabel',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
