import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/ops_colors.dart';
import '../../venues/application/venues_providers.dart';
import '../application/inventory_providers.dart';
import '../domain/inventory_v2.dart';
import 'inventory_widgets.dart';
import 'inventory_item_screen.dart';
import 'inventory_count_screen.dart';
import 'inventory_admin_screen.dart';
import 'inventory_import_screen.dart';
import 'inventory_action_sheet.dart';

class InventoryListScreen extends ConsumerStatefulWidget {
  const InventoryListScreen({super.key});
  @override
  ConsumerState<InventoryListScreen> createState() => _InventoryListState();
}

class _InventoryListState extends ConsumerState<InventoryListScreen> {
  int tab = 0;
  String group = 'All', query = '', status = 'All', sort = 'Area';
  String? area, subArea, category, subcategory;
  bool includeInactive = false;
  void open(Widget screen) => Navigator.of(context)
      .push(MaterialPageRoute<void>(builder: (_) => screen));
  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(
        body: InventoryEmpty('Choose a venue to see inventory.'),
      );
    }
    final scope = (venueId: venue.id, organizationId: venue.organizationId);
    final data = ref.watch(inventorySnapshotProvider(scope));
    final manager =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Inventory Hub'),
        actions: [
          if (manager)
            IconButton(
              tooltip: 'Review invoice or count sheet',
              icon: const Icon(Icons.upload_file_outlined),
              onPressed: () => open(InventoryImportScreen(scope: scope)),
            ),
          IconButton(
            tooltip: 'Areas and categories',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => open(InventoryAdminScreen(scope: scope)),
          ),
        ],
      ),
      body: data.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => InventoryLoadError(
          retry: () => ref.invalidate(inventorySnapshotProvider(scope)),
        ),
        data: (snapshot) => RefreshIndicator(
          onRefresh: () async {
            refreshInventory(ref, scope);
            await ref.read(inventorySnapshotProvider(scope).future);
          },
          child: LayoutBuilder(
            builder: (context, constraints) => ListView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              children: [
                Text(
                  venue.name,
                  style: Theme.of(context).textTheme.labelLarge,
                ),
                const SizedBox(height: 12),
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: SegmentedButton<int>(
                    segments: const [
                      ButtonSegment(
                        value: 0,
                        label: Text('Overview'),
                        icon: Icon(Icons.dashboard_outlined),
                      ),
                      ButtonSegment(
                        value: 1,
                        label: Text('Browse'),
                        icon: Icon(
                          Icons.inventory_2_outlined,
                        ),
                      ),
                      ButtonSegment(
                        value: 2,
                        label: Text('Counts'),
                        icon: Icon(
                          Icons.fact_check_outlined,
                        ),
                      ),
                      ButtonSegment(
                        value: 3,
                        label: Text('Replenish'),
                        icon: Icon(
                          Icons.shopping_basket_outlined,
                        ),
                      ),
                    ],
                    selected: {
                      tab,
                    },
                    onSelectionChanged: (v) => setState(() => tab = v.single),
                  ),
                ),
                const SizedBox(height: 20),
                if (tab == 0)
                  ..._overview(
                    snapshot,
                    scope,
                    manager,
                    constraints.maxWidth,
                  ),
                if (tab == 1) ..._browser(snapshot, scope),
                if (tab == 2) ..._counts(snapshot, scope),
                if (tab == 3) ..._replenishment(snapshot, scope),
              ],
            ),
          ),
        ),
      ),
      bottomNavigationBar: manager
          ? SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton.icon(
                  icon: Icon(
                    tab == 1 ? Icons.add : Icons.fact_check_outlined,
                  ),
                  label: Text(
                    tab == 1 ? 'Add inventory item' : 'Start count',
                  ),
                  onPressed: () => tab == 1
                      ? open(InventoryItemEditor(scope: scope))
                      : startInventoryCount(context, ref, scope),
                ),
              ),
            )
          : null,
    );
  }

  List<Widget> _overview(
    InventorySnapshot s,
    InventoryScope scope,
    bool manager,
    double width,
  ) {
    final positions = s.activePositions;
    final low =
        positions.where((p) => p.status == InventoryStockStatus.low).length;
    final out =
        positions.where((p) => p.status == InventoryStockStatus.out).length;
    final unpriced = positions
        .where(
          (p) => p.quantity == null || s.item(p.itemId)?.unitCostUsd == null,
        )
        .length;
    final metrics = [
      ('Inventory value', inventoryMoney(s.value)),
      ('Active items', '${s.items.where((i) => i.active).length}'),
      ('Below par', '$low'),
      ('Out of stock', '$out'),
      ('Not counted', '${s.outstandingCountRows}'),
      ('Variance · 30 days', inventoryMoney(s.recentVariance)),
    ];
    return [
      Wrap(
        spacing: 12,
        runSpacing: 12,
        children: [
          for (final m in metrics)
            SizedBox(
              width: (width - 32 - (width >= 760 ? 24 : 12)) /
                  (width >= 760 ? 3 : 2),
              child: Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  border: Border.all(color: context.ops.panelBorder),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.$1,
                      style: Theme.of(context).textTheme.labelMedium,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      m.$2,
                      style: Theme.of(context).textTheme.headlineSmall,
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      if (unpriced > 0)
        Padding(
          padding: const EdgeInsets.only(top: 10),
          child: Text(
            'Value includes known quantities with a unit cost. $unpriced location(s) need a cost or baseline.',
          ),
        ),
      if (manager) ...[
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed: () => _chooseAction(s, scope, 'RECEIVE'),
              icon: const Icon(Icons.add_box_outlined),
              label: const Text('Receive'),
            ),
            OutlinedButton.icon(
              onPressed: () => _chooseAction(s, scope, 'TRANSFER'),
              icon: const Icon(Icons.swap_horiz),
              label: const Text('Transfer'),
            ),
          ],
        ),
      ],
      inventoryHeading(context, 'Needs attention'),
      if (out == 0 && low == 0 && s.outstandingCountRows == 0)
        const InventoryEmpty('Stock is at par and counts are up to date.'),
      if (out > 0)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.error_outline),
          title: Text('$out stock locations are out'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() {
            tab = 1;
            status = 'Out of stock';
          }),
        ),
      if (low > 0)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.shopping_basket_outlined),
          title: Text('$low stock locations are below par'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => setState(() => tab = 3),
        ),
      for (final c in s.counts.where((c) => c.open))
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: const Icon(Icons.fact_check_outlined),
          title: Text('${_countTitle(s, c)} is incomplete'),
          subtitle: Text(
            MaterialLocalizations.of(context)
                .formatShortDate(c.startedAt.toLocal()),
          ),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => open(InventoryCountScreen(scope: scope, count: c)),
        ),
      inventoryHeading(context, 'Browse inventory'),
      Wrap(
        spacing: 8,
        children: [
          for (final g in inventoryGroups)
            ActionChip(
              label: Text(g),
              onPressed: () => setState(() {
                group = g;
                tab = 1;
              }),
            ),
        ],
      ),
    ];
  }

  bool _matches(InventorySnapshot s, InventoryStock p) {
    final i = s.item(p.itemId);
    if (i == null) return false;
    return (includeInactive || s.activeStock(p)) &&
        (group == 'All' || s.group(i) == group) &&
        i.name.toLowerCase().contains(query.toLowerCase()) &&
        (area == null || p.areaId == area) &&
        (subArea == null || p.subAreaId == subArea) &&
        (category == null || i.categoryId == category) &&
        (subcategory == null || i.subcategoryId == subcategory) &&
        (status == 'All' ||
            status ==
                switch (p.status) {
                  InventoryStockStatus.low => 'Low stock',
                  InventoryStockStatus.out => 'Out of stock',
                  InventoryStockStatus.available => 'Available',
                  InventoryStockStatus.unknown => 'No baseline'
                });
  }

  List<Widget> _filters(InventorySnapshot s) => [
        TextField(
          decoration: const InputDecoration(
            labelText: 'Search item name',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (v) => setState(() => query = v),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final g in inventoryGroups)
              ChoiceChip(
                label: Text(g),
                selected: group == g,
                onSelected: (_) => setState(() => group = g),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 12,
          runSpacing: 12,
          children: [
            _filter(
              'Area',
              area,
              s.areas.map((a) => (a.id, a.name)).toList(),
              (v) => setState(() {
                area = v;
                subArea = null;
              }),
            ),
            _filter(
              'Sub-area',
              subArea,
              s.subAreas
                  .where((a) => area == null || a.parentId == area)
                  .map((a) => (a.id, a.name))
                  .toList(),
              (v) => setState(() => subArea = v),
            ),
            _filter(
              'Category',
              category,
              s.categories.map((c) => (c.id, c.name)).toList(),
              (v) => setState(() {
                category = v;
                subcategory = null;
              }),
            ),
            _filter(
              'Subcategory',
              subcategory,
              s.subcategories
                  .where((c) => category == null || c.parentId == category)
                  .map((c) => (c.id, c.name))
                  .toList(),
              (v) => setState(() => subcategory = v),
            ),
            _filter(
              'Stock status',
              status == 'All' ? null : status,
              ['Available', 'Low stock', 'Out of stock', 'No baseline']
                  .map((s) => (s, s))
                  .toList(),
              (v) => setState(() => status = v ?? 'All'),
            ),
          ],
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: const Text('Include inactive items and areas'),
          value: includeInactive,
          onChanged: (v) => setState(() => includeInactive = v),
        ),
      ];
  Widget _filter(
    String label,
    String? value,
    List<(String, String)> options,
    ValueChanged<String?> changed,
  ) =>
      SizedBox(
        width: 210,
        child: DropdownButtonFormField<String>(
          key: ValueKey('$label:$value'),
          initialValue: options.any((o) => o.$1 == value) ? value : null,
          isExpanded: true,
          decoration: InputDecoration(labelText: label),
          items: [
            const DropdownMenuItem<String>(value: null, child: Text('All')),
            for (final o in options)
              DropdownMenuItem(
                value: o.$1,
                child: Text(o.$2, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: changed,
        ),
      );
  List<Widget> _browser(InventorySnapshot s, InventoryScope scope) {
    final visible =
        s.stock.where((p) => _matches(s, p)).map((p) => p.itemId).toSet();
    final items = s.items.where((i) => visible.contains(i.id));
    return [
      ..._filters(s),
      Text(
        '${items.length} items',
        style: Theme.of(context).textTheme.labelLarge,
      ),
      if (items.isEmpty) const InventoryEmpty('No items match these filters.'),
      for (final i in items)
        ListTile(
          contentPadding:
              const EdgeInsets.symmetric(vertical: 8, horizontal: 0),
          leading: const Icon(Icons.inventory_2_outlined),
          title: Text('${i.name}${i.active ? '' : ' · Inactive'}'),
          subtitle: Text(
            '${s.categoryName(i.categoryId)}${i.subcategoryId == null ? '' : ' → ${s.subcategoryName(i.subcategoryId)}'}\n${i.sizeLabel}',
          ),
          trailing: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${inventoryQuantity(s.totalFor(i.id))} ${i.displayUnit}${s.stock.any((p) => p.itemId == i.id && p.quantity == null) ? ' known' : ''}',
              ),
              Text(
                i.unitCostUsd == null
                    ? 'Cost not set'
                    : inventoryMoney(
                        inventoryValue(
                          inventoryQuantity(s.totalFor(i.id)),
                          i.unitCostUsd,
                        ),
                      ),
                style: Theme.of(context).textTheme.labelSmall,
              ),
            ],
          ),
          onTap: () => open(InventoryItemScreen(scope: scope, itemId: i.id)),
        ),
    ];
  }

  String _countTitle(InventorySnapshot s, InventoryCount c) => c.areaId == null
      ? '${c.type == 'full' ? 'Full' : 'Partial'} venue count'
      : '${s.areas.where((a) => a.id == c.areaId).firstOrNull?.name ?? 'Area'} count';
  List<Widget> _counts(InventorySnapshot s, InventoryScope scope) => [
        const Text(
          'Full counts require every selected location. Partial counts apply only entered quantities; blank rows keep their stock.',
        ),
        if (s.counts.isEmpty) const InventoryEmpty('No physical counts yet.'),
        for (final c in s.counts)
          ListTile(
            contentPadding: EdgeInsets.zero,
            leading: Icon(c.open ? Icons.fact_check_outlined : Icons.history),
            title: Text(_countTitle(s, c)),
            subtitle: Text(
              '${c.status.replaceAll('_', ' ')} • ${MaterialLocalizations.of(context).formatShortDate(c.startedAt.toLocal())}',
            ),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => open(InventoryCountScreen(scope: scope, count: c)),
          ),
        if (s.counts.length == 100)
          const Text('Showing the latest 100 count sessions.'),
      ];
  List<Widget> _replenishment(InventorySnapshot s, InventoryScope scope) {
    final stock = s.stock
        .where((p) => _matches(s, p) && p.shortage > BigInt.zero)
        .toList()
      ..sort(
        (a, b) => switch (sort) {
          'Largest shortage' => b.shortage.compareTo(a.shortage),
          'Category' => s
              .categoryName(s.item(a.itemId)?.categoryId)
              .compareTo(s.categoryName(s.item(b.itemId)?.categoryId)),
          _ => s.location(a).compareTo(s.location(b))
        },
      );
    return [
      const Text(
        'Use this list to replenish each area. Quantities stay in each item’s count unit.',
      ),
      const SizedBox(height: 12),
      ..._filters(s),
      DropdownButtonFormField<String>(
        initialValue: sort,
        decoration: const InputDecoration(labelText: 'Sort by'),
        items: [
          for (final v in ['Area', 'Category', 'Largest shortage'])
            DropdownMenuItem(value: v, child: Text(v)),
        ],
        onChanged: (v) => setState(() => sort = v ?? 'Area'),
      ),
      if (stock.isEmpty)
        const InventoryEmpty('No shortages match these filters.'),
      for (final p in stock)
        ListTile(
          contentPadding: const EdgeInsets.symmetric(vertical: 8),
          title: Text(s.item(p.itemId)!.name),
          subtitle:
              Text('${s.location(p)}\nCurrent ${p.quantity} • Par ${p.par}'),
          trailing: Text(
            'Need ${inventoryQuantity(p.shortage)}\n${s.item(p.itemId)!.displayUnit}',
            textAlign: TextAlign.end,
          ),
          onTap: () =>
              open(InventoryItemScreen(scope: scope, itemId: p.itemId)),
        ),
    ];
  }

  Future<void> _chooseAction(
    InventorySnapshot s,
    InventoryScope scope,
    String action,
  ) async {
    final chosen = await showDialog<InventoryStock>(
      context: context,
      builder: (context) => SimpleDialog(
        title: Text(
          action == 'TRANSFER' ? 'Transfer from' : 'Receive into',
        ),
        children: [
          for (final p in s.activePositions)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, p),
              child: Text(
                '${s.item(p.itemId)!.name} • ${s.location(p)}',
              ),
            ),
          if (s.activePositions.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('Add an item and a stock location first.'),
            ),
        ],
      ),
    );
    if (chosen == null || !mounted) return;
    await showInventoryAction(context, scope, s, chosen, action);
  }
}
