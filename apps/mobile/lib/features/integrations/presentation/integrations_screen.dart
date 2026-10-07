import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venues_providers.dart';
import '../application/integrations_providers.dart';
import '../domain/payroll_connection.dart';

/// Square/QuickBooks/Gusto connection status + connect/disconnect, per
/// features/integrations/README.md. Never renders a provider secret or raw OAuth token — the
/// client only ever sees the non-secret columns of `payroll_connections` (RLS + a column-level
/// grant hide the rest entirely, see supabase/migrations/20261002140000).
class IntegrationsScreen extends ConsumerWidget {
  const IntegrationsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final connectionsAsync =
        ref.watch(payrollConnectionsForVenueProvider(venue.id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Integrations'),
      ),
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.invalidate(payrollConnectionsForVenueProvider(venue.id)),
        child: connectionsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) =>
              const Center(child: Text('Could not load integrations.')),
          data: (connections) {
            final byProvider = {
              for (final connection in connections)
                connection.provider: connection,
            };
            return ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.point_of_sale_outlined),
                  title: const Text('POS'),
                  subtitle: const Text('Provider access, capabilities and schedule sync'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => context.push('/pos'),
                ),
                const Divider(),
                for (final provider in PayrollProvider.values)
                  _ProviderTile(
                    provider: provider,
                    venueId: venue.id,
                    connection: byProvider[provider.toDb()],
                  ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _ProviderTile extends ConsumerWidget {
  const _ProviderTile({
    required this.provider,
    required this.venueId,
    this.connection,
  });

  final PayrollProvider provider;
  final String venueId;
  final PayrollConnection? connection;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isConnected = connection?.isConnected ?? false;

    return ListTile(
      leading: Icon(
        isConnected ? Icons.check_circle_outline : Icons.circle_outlined,
      ),
      title: Text(provider.label),
      subtitle: Text(
        isConnected
            ? 'Connected${connection?.externalAccountId != null ? ' (${connection!.externalAccountId})' : ''}'
            : connection?.lastError ?? 'Not connected',
      ),
      trailing: isConnected
          ? OutlinedButton(
              onPressed: () => _disconnect(context, ref),
              child: const Text('Disconnect'),
            )
          : FilledButton(
              onPressed: () => _connect(context, ref),
              child: const Text('Connect'),
            ),
    );
  }

  Future<void> _connect(BuildContext context, WidgetRef ref) async {
    try {
      final url = await ref
          .read(integrationsRepositoryProvider)
          .createConnectUrl(provider, venueId);
      final launched =
          await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
      if (!launched && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not open the connection page.')),
        );
      }
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _disconnect(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(integrationsRepositoryProvider)
          .disconnect(provider, venueId);
      ref.invalidate(payrollConnectionsForVenueProvider(venueId));
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
