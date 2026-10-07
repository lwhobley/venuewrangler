import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../venues/application/venues_providers.dart';
import '../application/pos_providers.dart';
import '../domain/pos_check.dart';
import '../domain/pos_connection.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/status_chip.dart';

class PosManagementScreen extends ConsumerWidget {
  const PosManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    final connectionsAsync = ref.watch(posConnectionsProvider);
    final checksAsync = ref.watch(recentPosChecksProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Integrations · POS'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              ref.invalidate(posConnectionsProvider);
              ref.invalidate(recentPosChecksProvider);
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          // This legacy action only queued a menu command; no provider worker existed.
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Provider access and schedule publication',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Connections require provider approval, verified permissions, location and workforce mappings, and a configured server worker. Queued work is not a provider acknowledgment.',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Active Connections
          const Text(
            'Connections',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          connectionsAsync.when(
            data: (connections) {
              if (connections.isEmpty) {
                return const Card(
                  child: Padding(
                    padding: EdgeInsets.all(16.0),
                    child: Text(
                      'No POS connection configured for this venue. Provider onboarding is required.',
                    ),
                  ),
                );
              }
              return Column(
                children: connections
                    .map((c) => _ConnectionTile(connection: c, ref: ref))
                    .toList(),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Text('Error loading connections: $err'),
          ),
          const SizedBox(height: 24),

          // Inbound Checks Feed
          const Text(
            'Recent POS checks',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          checksAsync.when(
            data: (checks) {
              if (checks.isEmpty) {
                return const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32.0),
                    child: Text('No recent checks received from POS.'),
                  ),
                );
              }
              return Column(
                children:
                    checks.map((chk) => _CheckListTile(check: chk)).toList(),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Text('Error loading checks: $err'),
          ),
          const SizedBox(height: 24),
          const Text(
            'Choose your POS product',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          for (final product in _posProducts)
            Card(
              child: ExpansionTile(
                title: Text(product.name),
                subtitle: Text(product.status),
                childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
                children: [
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(product.requirement),
                  ),
                  const SizedBox(height: 8),
                  if (venue != null && connectionsAsync.hasValue)
                    Align(
                      alignment: Alignment.centerRight,
                      child: OutlinedButton(
                        onPressed: connectionsAsync.valueOrNull!.any(
                          (connection) => connection.provider == product.id,
                        )
                            ? null
                            : () async {
                                try {
                                  await ref
                                      .read(posRepositoryProvider)
                                      .requestConnection(
                                        venueId: venue.id,
                                        provider: product.id,
                                      );
                                  ref.invalidate(posConnectionsProvider);
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Setup request recorded. Provider authorization is still required.',
                                      ),
                                    ),
                                  );
                                } catch (_) {
                                  if (!context.mounted) return;
                                  ScaffoldMessenger.of(context).showSnackBar(
                                    const SnackBar(
                                      content: Text(
                                        'Could not request POS setup. Check your venue access.',
                                      ),
                                    ),
                                  );
                                }
                              },
                        child: Text(
                          connectionsAsync.valueOrNull!.any(
                            (connection) => connection.provider == product.id,
                          )
                              ? 'Setup requested'
                              : 'Request setup',
                        ),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

typedef _PosProduct = ({
  String id,
  String name,
  String status,
  String requirement
});

const _posProducts = <_PosProduct>[
  (
    id: 'toast',
    name: 'Toast',
    status: 'Approval required',
    requirement:
        'Partner approval, restaurant access and scheduling scopes are required. Schedule export is not enabled in this build.',
  ),
  (
    id: 'square',
    name: 'Square',
    status: 'Configuration required',
    requirement:
        'Merchant OAuth and Labor API scheduling permissions are required. Square payroll access does not authorize POS scheduling.',
  ),
  (
    id: 'spoton',
    name: 'SpotOn Restaurant',
    status: 'Approval required',
    requirement:
        'Provider and location access are required. Future schedule writes need a separately verified interface.',
  ),
  (
    id: 'clover',
    name: 'Clover',
    status: 'Schedule export unverified',
    requirement:
        'Merchant authorization is required. Actual employee shifts are not future scheduled shifts.',
  ),
  (
    id: 'lightspeed_restaurant_k',
    name: 'Lightspeed Restaurant K-Series',
    status: 'Approval required',
    requirement:
        'K-Series partner and merchant access must be verified independently.',
  ),
  (
    id: 'lightspeed_restaurant_l',
    name: 'Lightspeed Restaurant L-Series',
    status: 'Schedule export unverified',
    requirement:
        'L-Series restaurant API access and operations must be verified independently.',
  ),
  (
    id: 'oracle_simphony',
    name: 'Oracle MICROS Simphony',
    status: 'Configuration required',
    requirement:
        'The customer deployment, licensed interfaces and partner provisioning must be identified.',
  ),
  (
    id: 'ncr_aloha',
    name: 'NCR Voyix Aloha',
    status: 'Configuration required',
    requirement:
        'The exact Aloha product and approved API or middleware route must be identified.',
  ),
];

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({required this.connection, required this.ref});

  final PosConnection connection;
  final WidgetRef ref;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: const Icon(Icons.point_of_sale),
        ),
        title: Text(
          '${connection.provider.toUpperCase()} · ${connection.product}',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('Status: ${connection.readiness.replaceAll('_', ' ')}'),
        trailing: StatusChip(
          label: connection.isActive ? 'CONNECTED' : 'SETUP REQUIRED',
          tone: connection.isActive ? Tone.success : Tone.danger,
          dense: true,
        ),
        onTap: () => _showConnectionDetails(context, ref, connection),
      ),
    );
  }
}

Future<void> _showConnectionDetails(
  BuildContext context,
  WidgetRef ref,
  PosConnection connection,
) async {
  final repo = ref.read(posRepositoryProvider);
  await showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('${connection.provider} · ${connection.product}'),
      content: SizedBox(
        width: 440,
        child: FutureBuilder(
          future: Future.wait([
            repo.getCapabilities(connection.id),
            repo.getOutboundJobs(connection.id),
          ]),
          builder: (context, snapshot) {
            if (snapshot.hasError) {
              return const Text('Could not load integration status.');
            }
            if (!snapshot.hasData) return const CircularProgressIndicator();
            final capabilities = snapshot.data![0];
            final jobs = snapshot.data![1];
            return SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Readiness: ${connection.readiness.replaceAll('_', ' ')}',
                  ),
                  Text(
                    'Last inbound: ${connection.lastSyncAt?.toLocal() ?? 'never'}',
                  ),
                  const SizedBox(height: 12),
                  const Text('Verified capabilities'),
                  if (capabilities.isEmpty)
                    const Text('No capabilities verified.'),
                  for (final capability in capabilities)
                    Text('${capability['capability']}: ${capability['state']}'),
                  const SizedBox(height: 12),
                  const Text('Recent outbound operations'),
                  if (jobs.isEmpty) const Text('No published operations.'),
                  for (final job in jobs)
                    Text(
                      '${job['operation']}: ${job['status']}'
                      '${job['error_code'] == null ? '' : ' · ${job['error_code']}'}',
                    ),
                  const SizedBox(height: 12),
                  const Text(
                    'Publishing requires approved provider access and complete mappings.',
                  ),
                ],
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
        if (connection.isActive)
          FilledButton(
            onPressed: () async {
              try {
                final version = await repo.publishSchedule(connection.id);
                if (!context.mounted) return;
                Navigator.pop(context);
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(
                      'Schedule version $version queued. Check sync status for acknowledgment.',
                    ),
                  ),
                );
              } catch (_) {
                if (!context.mounted) return;
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'Could not publish. Check access, capabilities and mappings.',
                    ),
                  ),
                );
              }
            },
            child: const Text('Publish schedule'),
          ),
      ],
    ),
  );
}

class _CheckListTile extends StatelessWidget {
  const _CheckListTile({required this.check});

  final PosCheck check;

  @override
  Widget build(BuildContext context) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          child: Text(check.tableLabel ?? 'Bar'),
        ),
        title: Text('Check #${check.externalCheckId}'),
        subtitle: Text(
          'Total: \$${check.totalDollars.toStringAsFixed(2)} | Tip: \$${check.tipDollars.toStringAsFixed(2)}',
        ),
        trailing: Chip(
          label: Text(
            check.status.toUpperCase(),
            style: const TextStyle(fontSize: 10),
          ),
        ),
      ),
    );
  }
}
