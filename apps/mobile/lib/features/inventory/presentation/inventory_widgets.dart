import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/status_chip.dart';
import '../domain/inventory_v2.dart';

String inventoryError(Object error) => switch (error) {
      PostgrestException e => e.code == '42501'
          ? 'You do not have permission to change inventory here.'
          : e.message,
      AppError e => e.message,
      StateError e => e.message.toString(),
      FormatException e => e.message,
      _ => 'Could not save. Check your connection and try again.',
    };

String? inventoryNumberValidation(
  String? text, {
  bool optional = false,
  bool positive = false,
  int scale = 4,
}) {
  if (text == null || text.trim().isEmpty) {
    return optional ? null : 'Enter a quantity';
  }
  try {
    final number = inventoryDecimal(text.trim(), scale: scale);
    if (number < BigInt.zero || (positive && number == BigInt.zero)) {
      return positive
          ? 'Enter a number greater than zero'
          : 'Use zero or a positive number';
    }
    if (number.toString().length > 14) return 'That number is too large';
    return null;
  } on FormatException catch (e) {
    return e.message;
  }
}

class InventoryStatusBadge extends StatelessWidget {
  const InventoryStatusBadge(this.status, {super.key});
  final InventoryStockStatus status;
  @override
  Widget build(BuildContext context) => StatusChip(
        label: switch (status) {
          InventoryStockStatus.available => 'Available',
          InventoryStockStatus.low => 'Low stock',
          InventoryStockStatus.out => 'Out of stock',
          InventoryStockStatus.unknown => 'No baseline'
        },
        tone: switch (status) {
          InventoryStockStatus.available => Tone.success,
          InventoryStockStatus.low => Tone.warning,
          InventoryStockStatus.out => Tone.danger,
          InventoryStockStatus.unknown => Tone.neutral
        },
        dense: true,
      );
}

class InventoryEmpty extends StatelessWidget {
  const InventoryEmpty(this.message, {super.key, this.action});
  final String message;
  final Widget? action;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 20),
        child: Column(
          children: [
            const Icon(Icons.inventory_2_outlined, size: 40),
            const SizedBox(height: 12),
            Text(message, textAlign: TextAlign.center),
            if (action != null) ...[const SizedBox(height: 16), action!],
          ],
        ),
      );
}

class InventoryLoadError extends StatelessWidget {
  const InventoryLoadError({super.key, required this.retry});
  final VoidCallback retry;
  @override
  Widget build(BuildContext context) => InventoryEmpty(
        'Could not load inventory. Check your connection and retry.',
        action: OutlinedButton(onPressed: retry, child: const Text('Retry')),
      );
}

Future<bool> confirmInventory(
  BuildContext context,
  String title,
  String message,
) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Confirm'),
          ),
        ],
      ),
    ) ??
    false;

class InventoryHistoryTile extends StatelessWidget {
  const InventoryHistoryTile(this.entry, {super.key, this.actorName});
  final InventoryHistory entry;
  final String? actorName;
  @override
  Widget build(BuildContext context) {
    final date = MaterialLocalizations.of(context)
        .formatShortDate(entry.createdAt.toLocal());
    final change = entry.change == null
        ? 'Baseline ${entry.quantity ?? 'unknown'}'
        : '${inventoryDecimal(entry.change).isNegative ? '' : '+'}${inventoryQuantity(inventoryDecimal(entry.change))} ${entry.unit}';
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        switch (entry.action) {
          'COUNT' => Icons.fact_check_outlined,
          'RECEIVE' => Icons.add_box_outlined,
          'WASTE' => Icons.delete_outline,
          'TRANSFER_IN' || 'TRANSFER_OUT' => Icons.swap_horiz,
          _ => Icons.tune
        },
      ),
      title: Text(
        '${entry.action.replaceAll('_', ' ').toLowerCase()} • $change',
      ),
      subtitle: Text(
        '${entry.location}\n${entry.previous ?? 'Unknown'} → ${entry.quantity ?? 'Unknown'}${entry.reason == null ? '' : '\n${entry.reason}'}${entry.notes == null ? '' : '\n${entry.notes}'}\n$date • ${actorName ?? entry.actorName ?? (entry.actorId == null ? 'System / former team member' : 'Unnamed team member')}',
      ),
    );
  }
}

Widget inventoryHeading(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(top: 20, bottom: 10),
      child: Text(text, style: Theme.of(context).textTheme.titleLarge),
    );
Widget inventoryNumberField(
  TextEditingController controller,
  String label, {
  bool optional = false,
  bool positive = false,
  int scale = 4,
  VoidCallback? changed,
}) =>
    TextFormField(
      controller: controller,
      decoration: InputDecoration(labelText: label),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      validator: (v) => inventoryNumberValidation(
        v,
        optional: optional,
        positive: positive,
        scale: scale,
      ),
      onChanged: (_) => changed?.call(),
    );
