import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../venues/application/venues_providers.dart';
import '../application/pos_providers.dart';
import '../domain/pos_check.dart';
import '../domain/pos_connection.dart';

class PosManagementScreen extends ConsumerWidget {
  const PosManagementScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activeVenue = ref.watch(activeVenueProvider);
    final connectionsAsync = ref.watch(posConnectionsProvider);
    final checksAsync = ref.watch(recentPosChecksProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('POS Management'),
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
          // Outbound 86 Action Header
          Card(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            child: Padding(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text(
                        'Outbound POS Controls',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      ElevatedButton.icon(
                        icon: const Icon(Icons.block, size: 18),
                        label: const Text('86 Item (Toast)'),
                        onPressed: activeVenue != null
                            ? () => _show86Dialog(context, ref, activeVenue.id)
                            : null,
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Push out-of-stock items (86) directly to connected Toast terminals in real-time.',
                    style: TextStyle(fontSize: 12, color: Colors.grey),
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
                    child:
                        Text('No active POS connections found for this venue.'),
                  ),
                );
              }
              return Column(
                children: connections
                    .map((c) => _ConnectionTile(connection: c))
                    .toList(),
              );
            },
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (err, _) => Text('Error loading connections: $err'),
          ),
          const SizedBox(height: 24),

          // Inbound Checks Feed
          const Text(
            'Recent Ingested Checks',
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
        ],
      ),
    );
  }

  Future<void> _show86Dialog(
    BuildContext context,
    WidgetRef ref,
    String venueId,
  ) async {
    final itemCtrl = TextEditingController();
    bool isAvailable = false;

    await showDialog<void>(
      context: context,
      builder: (dialogCtx) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Update Item Availability (86)'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: itemCtrl,
                decoration: const InputDecoration(
                  labelText: 'Toast Item GUID or Name',
                  hintText: 'e.g. item-salmon-fillet',
                ),
              ),
              const SizedBox(height: 16),
              SwitchListTile(
                title: const Text('Available to Order'),
                subtitle: Text(
                  isAvailable ? 'Item in stock' : 'Item 86\'d (Out of stock)',
                ),
                value: isAvailable,
                onChanged: (val) => setState(() => isAvailable = val),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () async {
                final item = itemCtrl.text.trim();
                if (item.isEmpty) return;

                Navigator.of(dialogCtx).pop();
                try {
                  await ref.read(posRepositoryProvider).push86Item(
                        venueId: venueId,
                        itemGuid: item,
                        isAvailable: isAvailable,
                      );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text('Outbound 86 command sent for $item'),
                      ),
                    );
                  }
                } catch (e) {
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(content: Text('Failed to push 86: $e')),
                    );
                  }
                }
              },
              child: const Text('Send to POS'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConnectionTile extends StatelessWidget {
  const _ConnectionTile({required this.connection});

  final PosConnection connection;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: Theme.of(context).colorScheme.primaryContainer,
          child: const Icon(Icons.point_of_sale),
        ),
        title: Text(
          connection.provider.toUpperCase(),
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        subtitle: Text('Status: ${connection.status.toUpperCase()}'),
        trailing: Chip(
          label: Text(
            connection.isActive ? 'CONNECTED' : 'DISCONNECTED',
            style: const TextStyle(fontSize: 10, color: Colors.white),
          ),
          backgroundColor: connection.isActive ? Colors.green : Colors.red,
        ),
      ),
    );
  }
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
