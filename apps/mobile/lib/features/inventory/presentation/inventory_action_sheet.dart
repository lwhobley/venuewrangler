import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import '../../../core/auth/auth_providers.dart';
import '../application/inventory_providers.dart';
import '../domain/inventory_v2.dart';
import 'inventory_widgets.dart';

Future<void> showInventoryAction(
  BuildContext context,
  InventoryScope scope,
  InventorySnapshot snapshot,
  InventoryStock stock,
  String action,
) =>
    showDialog<void>(
      context: context,
      builder: (_) => _ActionSheet(
        scope: scope,
        snapshot: snapshot,
        stock: stock,
        action: action,
      ),
    );

class _ActionSheet extends ConsumerStatefulWidget {
  const _ActionSheet({
    required this.scope,
    required this.snapshot,
    required this.stock,
    required this.action,
  });
  final InventoryScope scope;
  final InventorySnapshot snapshot;
  final InventoryStock stock;
  final String action;
  @override
  ConsumerState<_ActionSheet> createState() => _ActionState();
}

class _ActionState extends ConsumerState<_ActionSheet> {
  final form = GlobalKey<FormState>();
  final quantity = TextEditingController(),
      reason = TextEditingController(),
      notes = TextEditingController();
  final operationId = const Uuid().v4();
  late final String? userId = ref.read(currentUserIdProvider);
  String? destination, error, wasteReason;
  bool busy = false;
  @override
  void dispose() {
    quantity.dispose();
    reason.dispose();
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final item = widget.snapshot.item(widget.stock.itemId)!;
    final destinations = widget.snapshot.activePositions
        .where(
          (p) =>
              p.itemId == item.id &&
              p.id != widget.stock.id &&
              p.quantity != null,
        )
        .toList();
    return AlertDialog(
      title: Text(
        switch (widget.action) {
          'RECEIVE' => 'Receive stock',
          'TRANSFER' => 'Transfer stock',
          'WASTE' => 'Record waste',
          'COUNT' => 'Count location',
          _ => 'Adjust stock'
        },
      ),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  item.name,
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                Text(
                  '${item.sizeLabel}\n${widget.snapshot.location(widget.stock)}',
                ),
                const SizedBox(height: 12),
                Text(
                  'Current: ${widget.stock.quantity ?? 'Unknown'} ${item.displayUnit}',
                ),
                const SizedBox(height: 16),
                inventoryNumberField(
                  quantity,
                  widget.action == 'ADJUSTMENT' || widget.action == 'COUNT'
                      ? 'New quantity'
                      : 'Quantity',
                  positive: !{'COUNT', 'ADJUSTMENT'}.contains(widget.action),
                ),
                if (widget.action == 'TRANSFER') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: destination,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'To location',
                    ),
                    items: [
                      for (final p in destinations)
                        DropdownMenuItem(
                          value: p.id,
                          child: Text(widget.snapshot.location(p)),
                        ),
                    ],
                    validator: (v) => v == null ? 'Choose a destination' : null,
                    onChanged:
                        busy ? null : (v) => setState(() => destination = v),
                  ),
                  if (destinations.isEmpty)
                    const Text(
                      'Add another location for this item before transferring.',
                    ),
                ],
                if (widget.action == 'WASTE') ...[
                  const SizedBox(height: 12),
                  DropdownButtonFormField<String>(
                    initialValue: wasteReason,
                    decoration: const InputDecoration(
                      labelText: 'Waste reason',
                    ),
                    items: [
                      for (final r in inventoryWasteReasons)
                        DropdownMenuItem(value: r, child: Text(r)),
                    ],
                    validator: (v) => v == null ? 'Choose a reason' : null,
                    onChanged: (v) => setState(() => wasteReason = v),
                  ),
                ],
                if (widget.action == 'ADJUSTMENT' ||
                    wasteReason == 'Other') ...[
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: reason,
                    decoration: const InputDecoration(labelText: 'Reason'),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'A reason is required'
                        : null,
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: notes,
                  decoration: const InputDecoration(
                    labelText: 'Notes (optional)',
                  ),
                  maxLines: 2,
                ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: busy ? null : () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: busy ? null : _save,
          child: Text(
            busy ? 'Saving…' : 'Confirm ${widget.action.toLowerCase()}',
          ),
        ),
      ],
    );
  }

  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      assertInventoryScope(ref, widget.scope, userId);
      await ref.read(inventoryRepositoryProvider).applyAction(
            widget.stock.id,
            widget.action,
            quantity.text.trim(),
            operationId: operationId,
            destinationId: destination,
            reason: widget.action == 'WASTE'
                ? (wasteReason == 'Other' ? reason.text.trim() : wasteReason)
                : reason.text.trim(),
            notes: notes.text.trim(),
          );
      if (!mounted) return;
      refreshInventory(ref, widget.scope);
      ref.invalidate(inventoryItemHistoryProvider(widget.stock.itemId));
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = inventoryError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
