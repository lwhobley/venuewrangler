import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../ai/application/ai_providers.dart';
import '../../ai/domain/ai_models.dart';
import '../../venues/application/venues_providers.dart';
import '../application/inventory_providers.dart';
import '../domain/inventory_item.dart';

/// Bar/kitchen inventory for the active venue. Every venue member can view; only a manager
/// tier can add/edit/delete (see inventory_schema.sql) — a non-manager's edit attempt is
/// denied by RLS and surfaces as a snackbar, same pattern as features/tasks.
class InventoryListScreen extends ConsumerWidget {
  const InventoryListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final itemsAsync = ref.watch(inventoryForVenueProvider(venue.id));

    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory'),
      ),
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.invalidate(inventoryForVenueProvider(venue.id)),
        child: itemsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load inventory.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(inventoryForVenueProvider(venue.id)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (items) {
            if (items.isEmpty) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: const Center(child: Text('No inventory items yet.')),
                  ),
                ),
              );
            }
            return ListView(
              children: [
                for (final item in items) _InventoryTile(item: item),
              ],
            );
          },
        ),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'parse-inventory',
            onPressed: () => _showParseDialog(context, ref, venue.id),
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('Parse from paste'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'add-item',
            onPressed: () => _showAddItemDialog(context, ref, venue.id),
            icon: const Icon(Icons.add),
            label: const Text('Add item'),
          ),
        ],
      ),
    );
  }

  Future<void> _showAddItemDialog(
    BuildContext context,
    WidgetRef ref,
    String venueId, {
    String? prefillName,
    num? prefillQuantity,
    String? prefillUnit,
    num? prefillUnitCost,
  }) async {
    final nameController = TextEditingController(text: prefillName);
    final quantityController =
        TextEditingController(text: prefillQuantity?.toString() ?? '');
    final unitController = TextEditingController(text: prefillUnit);
    final unitCostController =
        TextEditingController(text: prefillUnitCost?.toString() ?? '');

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add inventory item'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              autofocus: prefillName == null,
              decoration: const InputDecoration(labelText: 'Name'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: quantityController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Quantity'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: unitController,
              decoration:
                  const InputDecoration(labelText: 'Unit (e.g. bottle, case)'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: unitCostController,
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Unit cost (USD)'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (confirmed != true ||
        nameController.text.trim().isEmpty ||
        !context.mounted) {
      return;
    }

    try {
      await ref.read(inventoryRepositoryProvider).createItem(
            venueId: venueId,
            name: nameController.text.trim(),
            quantity: num.tryParse(quantityController.text.trim()),
            unit: unitController.text.trim().isEmpty
                ? null
                : unitController.text.trim(),
            unitCostUsd: num.tryParse(unitCostController.text.trim()),
          );
      ref.invalidate(inventoryForVenueProvider(venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = error.code == '42501'
          ? "You don't have permission to add inventory here."
          : 'Something went wrong. Please try again.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _showParseDialog(
    BuildContext context,
    WidgetRef ref,
    String venueId,
  ) async {
    final textController = TextEditingController();

    final pastedText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste an invoice or count sheet'),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Paste line items copied from an invoice or count sheet…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.of(context).pop(textController.text.trim()),
            child: const Text('Parse'),
          ),
        ],
      ),
    );

    if (pastedText == null || pastedText.isEmpty || !context.mounted) return;

    InventoryParseResult result;
    try {
      result = await ref
          .read(aiRepositoryProvider)
          .parseInventory(venueId: venueId, pastedText: pastedText);
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }

    if (!context.mounted) return;
    if (result.items.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nothing could be parsed from that text.'),
        ),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review parsed items'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final line in result.items)
                ListTile(
                  title: Text(line.name),
                  subtitle: Text(
                    [
                      if (line.quantity != null)
                        '${line.quantity} ${line.unit ?? ''}'.trim(),
                      if (line.unitCostUsd != null)
                        '\$${line.unitCostUsd}/unit',
                    ].join(' · '),
                  ),
                  trailing: TextButton(
                    onPressed: () {
                      Navigator.of(context).pop();
                      _showAddItemDialog(
                        context,
                        ref,
                        venueId,
                        prefillName: line.name,
                        prefillQuantity: line.quantity,
                        prefillUnit: line.unit,
                        prefillUnitCost: line.unitCostUsd,
                      );
                    },
                    child: const Text('Add'),
                  ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _InventoryTile extends ConsumerWidget {
  const _InventoryTile({required this.item});

  final InventoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: const Icon(Icons.inventory_2_outlined),
      title: Text(item.name),
      subtitle: Text(
        [
          if (item.quantity != null)
            '${item.quantity} ${item.unit ?? ''}'.trim(),
          if (item.unitCostUsd != null) '\$${item.unitCostUsd}/unit',
        ].join(' · '),
      ),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        onPressed: () => _delete(context, ref),
      ),
    );
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    try {
      await ref.read(inventoryRepositoryProvider).deleteItem(item.id);
      ref.invalidate(inventoryForVenueProvider(item.venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = error.code == '42501'
          ? "You don't have permission to delete this item."
          : 'Something went wrong. Please try again.';
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }
}
