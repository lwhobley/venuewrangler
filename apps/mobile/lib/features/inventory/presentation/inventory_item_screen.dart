import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../application/inventory_providers.dart';
import '../domain/inventory_item.dart';
import '../domain/inventory_v2.dart';
import 'inventory_widgets.dart';
import 'inventory_action_sheet.dart';

class InventoryItemScreen extends ConsumerWidget {
  const InventoryItemScreen({
    super.key,
    required this.scope,
    required this.itemId,
  });
  final InventoryScope scope;
  final String itemId;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final data = ref.watch(inventorySnapshotProvider(scope));
    final manager =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Inventory item')),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            InventoryLoadError(retry: () => refreshInventory(ref, scope)),
        data: (s) {
          final item = s.item(itemId);
          if (item == null) {
            return const InventoryEmpty(
              'This item is no longer available.',
            );
          }
          final locations = s.stock.where((p) => p.itemId == item.id).toList();
          final unknown = locations.where((p) => p.quantity == null).length;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                item.name,
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              Text(
                '${s.categoryName(item.categoryId)}${item.subcategoryId == null ? '' : ' → ${s.subcategoryName(item.subcategoryId)}'}',
              ),
              const SizedBox(height: 8),
              Text(
                item.sizeLabel,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (!item.active)
                const Text('Inactive • history and quantities are preserved'),
              inventoryHeading(
                context,
                unknown == 0 ? 'Total on hand' : 'Known on hand',
              ),
              Text(
                '${inventoryQuantity(s.totalFor(item.id))} ${item.displayUnit}',
                style: Theme.of(context).textTheme.headlineLarge,
              ),
              Text(
                item.unitCostUsd == null
                    ? 'Add a unit cost to calculate value'
                    : inventoryMoney(
                        inventoryValue(
                          inventoryQuantity(s.totalFor(item.id)),
                          item.unitCostUsd,
                        ),
                      ),
              ),
              if (unknown > 0)
                Text(
                  '$unknown location(s) need an opening count; this total excludes unknown quantities.',
                ),
              if (item.supplier?.isNotEmpty == true)
                Text('Supplier: ${item.supplier}'),
              if (item.notes?.isNotEmpty == true)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(item.notes!),
                ),
              if (manager)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        onPressed: () => Navigator.push(
                          context,
                          MaterialPageRoute<String>(
                            builder: (_) => InventoryItemEditor(
                              scope: scope,
                              item: item,
                            ),
                          ),
                        ),
                        icon: const Icon(Icons.edit_outlined),
                        label: const Text('Edit item'),
                      ),
                      if (item.active)
                        OutlinedButton.icon(
                          onPressed: () => showInventoryLocation(
                            context,
                            scope,
                            s,
                            item,
                          ),
                          icon: const Icon(Icons.add_location_alt_outlined),
                          label: const Text('Add location'),
                        ),
                      if (item.active)
                        TextButton(
                          onPressed: () async {
                            final userId = ref.read(currentUserIdProvider);
                            if (!await confirmInventory(
                              context,
                              'Make item inactive?',
                              'Existing stock and history will remain. This item will be excluded from new counts and active inventory.',
                            )) {
                              return;
                            }
                            try {
                              assertInventoryScope(ref, scope, userId);
                              await ref
                                  .read(inventoryRepositoryProvider)
                                  .deleteItem(item.id);
                              refreshInventory(ref, scope);
                            } catch (e) {
                              if (context.mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    content: Text(inventoryError(e)),
                                  ),
                                );
                              }
                            }
                          },
                          child: const Text('Make inactive'),
                        ),
                    ],
                  ),
                ),
              inventoryHeading(context, 'Locations'),
              if (locations.isEmpty)
                const InventoryEmpty('Add the first location for this item.'),
              for (final p in locations)
                Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              s.location(p),
                              style: Theme.of(context).textTheme.titleMedium,
                            ),
                          ),
                          InventoryStatusBadge(p.status),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '${p.quantity ?? 'Unknown'} ${item.displayUnit} • Par ${p.par ?? 'not set'}',
                      ),
                      if (p.shortage > BigInt.zero)
                        Text(
                          '${inventoryQuantity(p.shortage)} ${item.displayUnit} below par',
                        ),
                      if (!s.activeStock(p))
                        const Text('Inactive item or location'),
                      if (manager && s.activeStock(p))
                        Wrap(
                          spacing: 8,
                          runSpacing: 4,
                          children: [
                            for (final action in [
                              'COUNT',
                              'RECEIVE',
                              'TRANSFER',
                              'WASTE',
                              'ADJUSTMENT',
                            ])
                              TextButton(
                                onPressed: () => showInventoryAction(
                                  context,
                                  scope,
                                  s,
                                  p,
                                  action,
                                ),
                                child: Text(
                                  action == 'ADJUSTMENT'
                                      ? 'Adjust'
                                      : action[0] +
                                          action.substring(1).toLowerCase(),
                                ),
                              ),
                            TextButton(
                              onPressed: () => showInventoryLocation(
                                context,
                                scope,
                                s,
                                item,
                                stock: p,
                              ),
                              child: const Text('Set par'),
                            ),
                          ],
                        ),
                      const Divider(),
                    ],
                  ),
                ),
              inventoryHeading(context, 'Recent history'),
              ref.watch(inventoryItemHistoryProvider(item.id)).when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, __) => InventoryLoadError(
                      retry: () =>
                          ref.invalidate(inventoryItemHistoryProvider(item.id)),
                    ),
                    data: (entries) => Column(
                      children: [
                        if (entries.isEmpty)
                          const InventoryEmpty('No stock changes yet.'),
                        for (final h in entries) InventoryHistoryTile(h),
                        if (entries.length == 100)
                          const Text('Showing the latest 100 actions.'),
                      ],
                    ),
                  ),
            ],
          );
        },
      ),
    );
  }
}

class InventoryItemEditor extends ConsumerStatefulWidget {
  const InventoryItemEditor({
    super.key,
    required this.scope,
    this.item,
    this.prefill = const {},
  });
  final InventoryScope scope;
  final InventoryItem? item;
  final Map<String, String?> prefill;
  @override
  ConsumerState<InventoryItemEditor> createState() => _ItemEditorState();
}

class _ItemEditorState extends ConsumerState<InventoryItemEditor> {
  final form = GlobalKey<FormState>();
  late final name =
      TextEditingController(text: widget.item?.name ?? widget.prefill['name']);
  late final size = TextEditingController(
    text: widget.item?.sizeAmount ?? widget.prefill['size_amount'],
  );
  late final cost = TextEditingController(
    text:
        widget.item?.unitCostUsd?.toString() ?? widget.prefill['unit_cost_usd'],
  );
  late final supplier = TextEditingController(text: widget.item?.supplier),
      notes = TextEditingController(text: widget.item?.notes);
  late final custom = TextEditingController(
    text: widget.item?.customCountUnit ?? widget.prefill['custom_count_unit'],
  );
  late String countUnit =
      widget.item?.countUnit ?? widget.prefill['count_unit'] ?? 'Each';
  late String? sizeUnit = widget.item?.sizeUnit ?? widget.prefill['size_unit'],
      category = widget.item?.categoryId,
      subcategory = widget.item?.subcategoryId;
  late bool active = widget.item?.active ?? true;
  late final String? userId;
  @override
  void initState() {
    super.initState();
    userId = ref.read(currentUserIdProvider);
  }

  bool busy = false;
  String? error;
  @override
  void dispose() {
    for (final c in [name, size, cost, supplier, notes, custom]) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final data = ref.watch(inventorySnapshotProvider(widget.scope));
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.item == null ? 'Add inventory item' : 'Edit inventory item',
        ),
      ),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => InventoryLoadError(
          retry: () => refreshInventory(ref, widget.scope),
        ),
        data: (s) => Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 760),
            child: Form(
              key: form,
              child: ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  Text(
                    'What are we counting?',
                    style: Theme.of(context).textTheme.headlineSmall,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: name,
                    decoration: const InputDecoration(
                      labelText: 'Item name',
                      hintText: 'Tito’s Vodka',
                    ),
                    validator: (v) => v == null || v.trim().isEmpty
                        ? 'Enter an item name'
                        : null,
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: category,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Category',
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('Uncategorized'),
                      ),
                      for (final c in s.categories.where(
                        (c) => c.active || c.id == category,
                      ))
                        DropdownMenuItem(
                          value: c.id,
                          child: Text('${c.group} • ${c.name}'),
                        ),
                    ],
                    onChanged: (v) => setState(() {
                      category = v;
                      subcategory = null;
                    }),
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    key: ValueKey('subcategory:$category'),
                    initialValue: subcategory,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Subcategory (optional)',
                    ),
                    items: [
                      const DropdownMenuItem<String>(
                        value: null,
                        child: Text('None'),
                      ),
                      for (final c in s.subcategories.where(
                        (c) =>
                            c.parentId == category &&
                            (c.active || c.id == subcategory),
                      ))
                        DropdownMenuItem(
                          value: c.id,
                          child: Text(c.name),
                        ),
                    ],
                    onChanged: (v) => setState(() => subcategory = v),
                  ),
                  inventoryHeading(context, 'Size and count unit'),
                  const Text(
                    'Size describes one container. Quantities use the count unit; no case/bottle conversions are applied.',
                  ),
                  const SizedBox(height: 16),
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: inventoryNumberField(
                          size,
                          'Size amount (optional)',
                          optional: true,
                          positive: true,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: DropdownButtonFormField<String>(
                          initialValue: sizeUnit,
                          decoration: const InputDecoration(
                            labelText: 'Size unit',
                          ),
                          items: [
                            const DropdownMenuItem<String>(
                              value: null,
                              child: Text('None'),
                            ),
                            for (final u in inventorySizeUnits)
                              DropdownMenuItem(
                                value: u,
                                child: Text(u),
                              ),
                          ],
                          validator: (v) =>
                              size.text.trim().isNotEmpty && v == null
                                  ? 'Choose a size unit'
                                  : size.text.trim().isEmpty && v != null
                                      ? 'Enter the size amount'
                                      : null,
                          onChanged: (v) => setState(() => sizeUnit = v),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  DropdownButtonFormField<String>(
                    initialValue: countUnit,
                    decoration: const InputDecoration(
                      labelText: 'Count unit',
                    ),
                    items: [
                      for (final u in inventoryCountUnits)
                        DropdownMenuItem(value: u, child: Text(u)),
                    ],
                    onChanged: (v) => setState(() => countUnit = v ?? 'Each'),
                  ),
                  if (countUnit == 'Custom') ...[
                    const SizedBox(height: 16),
                    TextFormField(
                      controller: custom,
                      decoration: const InputDecoration(
                        labelText: 'Custom count unit',
                      ),
                      validator: (v) => v == null || v.trim().isEmpty
                          ? 'Name the count unit'
                          : null,
                    ),
                  ],
                  inventoryHeading(context, 'Cost and purchasing'),
                  inventoryNumberField(
                    cost,
                    'Unit cost (USD, per count unit)',
                    optional: true,
                    scale: 2,
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: supplier,
                    decoration: const InputDecoration(
                      labelText: 'Supplier (optional)',
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: notes,
                    decoration: const InputDecoration(
                      labelText: 'Notes (optional)',
                    ),
                    maxLines: 3,
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Active item'),
                    subtitle: const Text(
                      'Inactive items retain stock and history.',
                    ),
                    value: active,
                    onChanged: (v) => setState(() => active = v),
                  ),
                  if (error != null)
                    Text(
                      error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: FilledButton(
            onPressed: busy ? null : _save,
            child: Text(busy ? 'Saving…' : 'Save item'),
          ),
        ),
      ),
    );
  }

  Future<void> _save() async {
    if (form.currentState?.validate() != true) return;
    setState(() {
      busy = true;
      error = null;
    });
    try {
      assertInventoryScope(ref, widget.scope, userId);
      final id = await ref.read(inventoryRepositoryProvider).saveItem(
            widget.scope.venueId,
            {
              'name': name.text.trim(),
              'category_id': category,
              'subcategory_id': subcategory,
              'size_amount': size.text.trim().isEmpty ? null : size.text.trim(),
              'size_unit': sizeUnit,
              'count_unit': countUnit,
              'custom_count_unit':
                  countUnit == 'Custom' ? custom.text.trim() : null,
              'unit_cost_usd':
                  cost.text.trim().isEmpty ? null : cost.text.trim(),
              'supplier':
                  supplier.text.trim().isEmpty ? null : supplier.text.trim(),
              'notes': notes.text.trim().isEmpty ? null : notes.text.trim(),
              'is_active': active,
            },
            id: widget.item?.id,
          );
      if (!mounted) return;
      refreshInventory(ref, widget.scope);
      Navigator.pop(context, id);
    } catch (e) {
      if (mounted) setState(() => error = inventoryError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

Future<void> showInventoryLocation(
  BuildContext context,
  InventoryScope scope,
  InventorySnapshot snapshot,
  InventoryItem item, {
  InventoryStock? stock,
}) =>
    showDialog<void>(
      context: context,
      builder: (_) => _LocationSheet(
        scope: scope,
        snapshot: snapshot,
        item: item,
        stock: stock,
      ),
    );

class _LocationSheet extends ConsumerStatefulWidget {
  const _LocationSheet({
    required this.scope,
    required this.snapshot,
    required this.item,
    this.stock,
  });
  final InventoryScope scope;
  final InventorySnapshot snapshot;
  final InventoryItem item;
  final InventoryStock? stock;
  @override
  ConsumerState<_LocationSheet> createState() => _LocationState();
}

class _LocationState extends ConsumerState<_LocationSheet> {
  final form = GlobalKey<FormState>();
  late String? area = widget.stock?.areaId, subArea = widget.stock?.subAreaId;
  late final par = TextEditingController(text: widget.stock?.par);
  late final String? userId;
  @override
  void initState() {
    super.initState();
    userId = ref.read(currentUserIdProvider);
  }

  bool busy = false;
  String? error;
  @override
  void dispose() {
    par.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
          widget.stock == null ? 'Add stock location' : 'Set location par',
        ),
        content: SizedBox(
          width: 480,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(widget.item.name),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  initialValue: area,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Area'),
                  items: [
                    for (final a
                        in widget.snapshot.areas.where((a) => a.active))
                      DropdownMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  validator: (v) => v == null ? 'Choose an area' : null,
                  onChanged: widget.stock != null || busy
                      ? null
                      : (v) => setState(() {
                            area = v;
                            subArea = null;
                          }),
                ),
                const SizedBox(height: 16),
                DropdownButtonFormField<String>(
                  key: ValueKey('sub-area:$area'),
                  initialValue: subArea,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Sub-area (optional)',
                  ),
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Whole area'),
                    ),
                    for (final a in widget.snapshot.subAreas
                        .where((a) => a.active && a.parentId == area))
                      DropdownMenuItem(value: a.id, child: Text(a.name)),
                  ],
                  onChanged: widget.stock != null || busy
                      ? null
                      : (v) => setState(() => subArea = v),
                ),
                const SizedBox(height: 16),
                inventoryNumberField(
                  par,
                  'Par level (optional)',
                  optional: true,
                ),
                if (widget.stock == null)
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'A new location starts at zero. Receive or count stock to record its opening quantity.',
                    ),
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
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy ? null : _save,
            child: Text(busy ? 'Saving…' : 'Save location'),
          ),
        ],
      );
  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    setState(() => busy = true);
    try {
      assertInventoryScope(ref, widget.scope, userId);
      final existing = widget.snapshot.stock.where(
        (stock) =>
            stock.itemId == widget.item.id &&
            stock.areaId == area &&
            stock.subAreaId == subArea,
      );
      final currentPar = existing.isEmpty ? null : existing.first.par;
      await ref.read(inventoryRepositoryProvider).setStock(
            widget.item.id,
            area!,
            subAreaId: subArea,
            par: par.text.trim().isEmpty && widget.stock == null
                ? currentPar
                : (par.text.trim().isEmpty ? null : par.text.trim()),
          );
      if (!mounted) return;
      refreshInventory(ref, widget.scope);
      Navigator.pop(context);
    } catch (e) {
      if (mounted) setState(() => error = inventoryError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
