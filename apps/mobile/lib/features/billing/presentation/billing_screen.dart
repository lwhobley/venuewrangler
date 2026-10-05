import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venues_providers.dart';
import '../application/billing_providers.dart';
import '../domain/subscription.dart';

/// Shows the organization's subscription status. App subscriptions are sold directly to
/// organizations outside the mobile app; no in-app link initiates a digital purchase.
/// Event deposits are separate payments for real-world venue services.
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
    final depositAccountAsync =
        ref.watch(depositAccountForOrgProvider(organizationId));

    return Scaffold(
      appBar: AppBar(title: const Text('Billing')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(subscriptionForOrgProvider(organizationId));
          ref.invalidate(depositAccountForOrgProvider(organizationId));
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
            const SizedBox(height: 32),
            Text(
              'Event deposit payments',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            const SizedBox(height: 8),
            const Text(
              'Deposits are paid to your organization’s Stripe account. App subscription payments are separate.',
            ),
            const SizedBox(height: 12),
            depositAccountAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Text(
                'Could not load deposit account status. Pull down to retry.',
              ),
              data: (account) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        !account.connected
                            ? 'Account setup needed'
                            : account.ready && account.payoutsReady
                                ? 'Ready to collect deposits and receive payouts'
                                : account.ready
                                    ? 'Card payments are enabled; payouts are still being verified'
                                    : 'Stripe is verifying your account',
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  if (!account.ready || !account.payoutsReady)
                    FilledButton.icon(
                      onPressed: () => _setupDepositAccount(
                        context,
                        ref,
                        organizationId,
                        account.connected,
                      ),
                      icon: const Icon(Icons.account_balance_outlined),
                      label: Text(
                        account.connected
                            ? 'Continue Stripe setup'
                            : 'Set up deposit account',
                      ),
                    ),
                  TextButton(
                    onPressed: () => ref.invalidate(
                      depositAccountForOrgProvider(organizationId),
                    ),
                    child: const Text('Refresh account status'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _setupDepositAccount(
    BuildContext context,
    WidgetRef ref,
    String organizationId,
    bool connected,
  ) async {
    String country = '';
    if (!connected) {
      final selected = await showDialog<String>(
        context: context,
        builder: (dialogContext) {
          return AlertDialog(
            title: const Text('Business country'),
            content: TextField(
              onChanged: (value) => country = value,
              autofocus: true,
              maxLength: 2,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                hintText: 'US',
                helperText:
                    'Enter the two-letter country code for your organization.',
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  country.trim().toUpperCase(),
                ),
                child: const Text('Continue'),
              ),
            ],
          );
        },
      );
      if (selected == null || selected.length != 2) return;
      country = selected;
    }
    try {
      final url = await ref
          .read(billingRepositoryProvider)
          .createDepositAccountOnboardingUrl(organizationId, country: country);
      if (!context.mounted) return;
      await _openUrl(context, url);
      ref.invalidate(depositAccountForOrgProvider(organizationId));
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _openUrl(BuildContext context, String url) async {
    final uri = Uri.parse(url);
    final launched = await launchUrl(uri, mode: LaunchMode.externalApplication);
    if (!launched && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not open the billing page.')),
      );
    }
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.subscription});

  final Subscription? subscription;

  @override
  Widget build(BuildContext context) {
    final status = subscription?.status ?? 'none';
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 4),
            Text(status, style: Theme.of(context).textTheme.headlineSmall),
            if (subscription?.currentPeriodEnd != null) ...[
              const SizedBox(height: 8),
              Text(
                subscription!.cancelAtPeriodEnd
                    ? 'Cancels on ${subscription!.currentPeriodEnd}'
                    : 'Renews on ${subscription!.currentPeriodEnd}',
              ),
            ],
          ],
        ),
      ),
    );
  }
}
