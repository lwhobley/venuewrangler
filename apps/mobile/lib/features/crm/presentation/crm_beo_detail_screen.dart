import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/crm_providers.dart';
import '../domain/crm_beo.dart';
import '../domain/crm_beo_charge.dart';

class CrmBeoDetailScreen extends ConsumerWidget {
  const CrmBeoDetailScreen({super.key, required this.beo});

  final CrmBeo beo;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final charges = ref.watch(crmBeoChargesProvider(beo.id));
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Banquet event order')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(crmBeoChargesProvider(beo.id));
          await ref.read(crmBeoChargesProvider(beo.id).future);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 820),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _section(context, 'BANQUET EVENT ORDER', [
                      Text(
                        beo.eventName,
                        style: theme.textTheme.headlineMedium,
                      ),
                      const SizedBox(height: 8),
                      Chip(label: Text(beo.status.toUpperCase())),
                      const Divider(height: 32),
                      _detail('Event date', _date(beo.eventDate)),
                      _detail('Event type', beo.eventType),
                      _detail('Guests', beo.guestCount?.toString()),
                      _detail('Space', beo.venueSpace),
                      _detail('Setup style', beo.setupStyle),
                      _detail('Lead reference', beo.leadId),
                      _detail('Assigned representative', beo.assignedRepId),
                    ]),
                    const SizedBox(height: 16),
                    _section(context, 'Food and beverage', [
                      _detail('Appetizers', beo.menuAppetizers),
                      _detail('Entrées', beo.menuEntrees),
                      _detail('Desserts', beo.menuDesserts),
                      _detail('Bar package', beo.menuBarPackage),
                    ]),
                    const SizedBox(height: 16),
                    _section(context, 'Service instructions', [
                      _detail('Special requirements', beo.specialRequirements),
                      _detail('Internal notes', beo.internalNotes),
                    ]),
                    const SizedBox(height: 16),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    'Charges',
                                    style: theme.textTheme.titleLarge,
                                  ),
                                ),
                                TextButton.icon(
                                  onPressed: () => _addCharge(context, ref),
                                  icon: const Icon(Icons.add),
                                  label: const Text('Add charge'),
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            charges.when(
                              loading: () => const Center(
                                child: CircularProgressIndicator(),
                              ),
                              error: (_, __) => TextButton(
                                onPressed: () => ref
                                    .invalidate(crmBeoChargesProvider(beo.id)),
                                child:
                                    const Text('Could not load charges. Retry'),
                              ),
                              data: (rows) => Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  if (rows.isEmpty)
                                    const Padding(
                                      padding:
                                          EdgeInsets.symmetric(vertical: 12),
                                      child: Text(
                                        'No itemized charges recorded yet.',
                                      ),
                                    ),
                                  for (final charge in rows)
                                    ListTile(
                                      contentPadding: EdgeInsets.zero,
                                      title: Text(charge.description),
                                      subtitle:
                                          Text(charge.category.toUpperCase()),
                                      trailing: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            _money(charge.signedAmountCents),
                                          ),
                                          IconButton(
                                            tooltip: 'Remove charge',
                                            icon: const Icon(
                                              Icons.delete_outline,
                                            ),
                                            onPressed: () => _removeCharge(
                                              context,
                                              ref,
                                              charge,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  const Divider(),
                                  _detail(
                                    'Recorded total',
                                    _money(
                                      rows.fold<int>(
                                        0,
                                        (total, charge) =>
                                            total + charge.signedAmountCents,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            if (beo.fbMinimumCents != null) ...[
                              const SizedBox(height: 12),
                              _detail(
                                'Food & beverage minimum',
                                _money(beo.fbMinimumCents!),
                              ),
                              const Text(
                                'The minimum is a commitment, not an additional charge.',
                              ),
                            ],
                            const SizedBox(height: 12),
                            Text(
                              'Totals include recorded charge lines only. Add taxes and service charges as separate lines when they apply.',
                              style: theme.textTheme.bodySmall,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Created ${_date(beo.createdAt) ?? ''}',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall,
                    ),
                    Text(
                      'Updated ${_date(beo.updatedAt) ?? ''}',
                      textAlign: TextAlign.end,
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static Widget _detail(String label, String? value) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 3),
          SelectableText(value),
        ],
      ),
    );
  }

  static Widget _section(
    BuildContext context,
    String title,
    List<Widget> contents,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            ...contents,
          ],
        ),
      ),
    );
  }

  static String? _date(DateTime? value) {
    if (value == null) return null;
    final local = value.toLocal().toString();
    return local.length >= 16 ? local.substring(0, 16) : local;
  }

  static String _money(int cents) {
    final absolute = cents.abs();
    final dollars = (absolute ~/ 100).toString().replaceAllMapped(
          RegExp(r'\B(?=(\d{3})+(?!\d))'),
          (_) => ',',
        );
    final result = StringBuffer();
    if (cents < 0) result.write('-');
    result.write(r'$');
    result.write(dollars);
    result.write('.');
    result.write((absolute % 100).toString().padLeft(2, '0'));
    return result.toString();
  }

  Future<void> _addCharge(BuildContext context, WidgetRef ref) async {
    final draft = await AddBeoChargeDialog.show(context);
    if (draft == null) return;
    try {
      await ref.read(crmRepositoryProvider).addBeoCharge(
            beoId: beo.id,
            venueId: beo.venueId,
            description: draft.description,
            category: draft.category,
            amountCents: draft.cents,
          );
      ref.invalidate(crmBeoChargesProvider(beo.id));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not add charge.')),
        );
      }
    }
  }

  Future<void> _removeCharge(
    BuildContext context,
    WidgetRef ref,
    CrmBeoCharge charge,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Remove charge?'),
        content: Text(charge.description),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    try {
      await ref
          .read(crmRepositoryProvider)
          .deleteBeoCharge(chargeId: charge.id);
      ref.invalidate(crmBeoChargesProvider(beo.id));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not remove charge.')),
        );
      }
    }
  }
}

/// Amount in cents from user input ("12", "12.5", "12.50"); null unless positive with at most two
/// decimals and within a 32-bit int.
int? parseChargeCents(String input) {
  final value = input.trim();
  if (!RegExp(r'^\d+(?:\.\d{1,2})?$').hasMatch(value)) return null;
  final parts = value.split('.');
  final whole = int.tryParse(parts.first);
  if (whole == null) return null;
  final cents =
      int.parse(parts.length == 1 ? '0' : parts.last.padRight(2, '0'));
  final total = whole * 100 + cents;
  return total > 0 && total <= 2147483647 ? total : null;
}

typedef BeoChargeDraft = ({String description, String category, int cents});

/// The "Add BEO charge" form. A StatefulWidget of its own so the text controllers are disposed
/// when the dialog is really gone — disposing them right after `showDialog` returns races the
/// route's exit animation, during which the fields are still built.
class AddBeoChargeDialog extends StatefulWidget {
  const AddBeoChargeDialog({super.key});

  static Future<BeoChargeDraft?> show(BuildContext context) =>
      showDialog<BeoChargeDraft>(
        context: context,
        builder: (_) => const AddBeoChargeDialog(),
      );

  @override
  State<AddBeoChargeDialog> createState() => _AddBeoChargeDialogState();
}

class _AddBeoChargeDialogState extends State<AddBeoChargeDialog> {
  final _formKey = GlobalKey<FormState>();
  final _description = TextEditingController();
  final _amount = TextEditingController();
  String _category = CrmBeoCharge.categories.first;

  @override
  void dispose() {
    _description.dispose();
    _amount.dispose();
    super.dispose();
  }

  void _submit() {
    if (!_formKey.currentState!.validate()) return;
    final BeoChargeDraft draft = (
      description: _description.text.trim(),
      category: _category,
      cents: parseChargeCents(_amount.text)!,
    );
    Navigator.pop(context, draft);
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add BEO charge'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _description,
              decoration: const InputDecoration(labelText: 'Description'),
              maxLength: 160,
              validator: (value) => value == null || value.trim().isEmpty
                  ? 'Enter a description'
                  : null,
            ),
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final item in CrmBeoCharge.categories)
                  DropdownMenuItem(value: item, child: Text(item)),
              ],
              onChanged: (value) {
                if (value != null) setState(() => _category = value);
              },
            ),
            TextFormField(
              controller: _amount,
              decoration: const InputDecoration(
                labelText: 'Amount',
                prefixText: r'$',
              ),
              keyboardType:
                  const TextInputType.numberWithOptions(decimal: true),
              validator: (value) => parseChargeCents(value ?? '') == null
                  ? 'Enter a positive amount, up to 2 decimals'
                  : null,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Cancel'),
        ),
        FilledButton(onPressed: _submit, child: const Text('Add')),
      ],
    );
  }
}
