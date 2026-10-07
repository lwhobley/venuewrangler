import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../application/inventory_providers.dart';
import '../domain/inventory_v2.dart';
import 'inventory_widgets.dart';

class InventoryAdminScreen extends ConsumerWidget {
  const InventoryAdminScreen({super.key, required this.scope});
  final InventoryScope scope;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final manager =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
    final role = ref.watch(myVenueRoleProvider).valueOrNull;
    final orgAdmin =
        role == 'organization_owner' || role == 'organization_admin';
    return Scaffold(
      appBar: AppBar(title: const Text('Areas & categories')),
      body: ref.watch(inventorySnapshotProvider(scope)).when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (_, __) =>
                InventoryLoadError(retry: () => refreshInventory(ref, scope)),
            data: (s) => ListView(
              padding: const EdgeInsets.all(16),
              children: [
                const Text(
                  'Areas belong to this venue. Categories are shared across your organization. Making either inactive preserves existing stock and history.',
                ),
                inventoryHeading(context, 'Venue areas'),
                if (manager)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () =>
                          _edit(context, scope, s, 'inventory_areas'),
                      icon: const Icon(Icons.add),
                      label: const Text('Add area'),
                    ),
                  ),
                for (final a in s.areas)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('${a.name}${a.active ? '' : ' · Inactive'}'),
                    trailing: manager
                        ? IconButton(
                            tooltip: 'Edit ${a.name}',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _edit(
                              context,
                              scope,
                              s,
                              'inventory_areas',
                              id: a.id,
                              name: a.name,
                              active: a.active,
                            ),
                          )
                        : null,
                    children: [
                      for (final sub
                          in s.subAreas.where((sub) => sub.parentId == a.id))
                        ListTile(
                          title: Text(
                            '${sub.name}${sub.active ? '' : ' · Inactive'}',
                          ),
                          trailing: manager
                              ? IconButton(
                                  tooltip: 'Edit ${sub.name}',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _edit(
                                    context,
                                    scope,
                                    s,
                                    'inventory_sub_areas',
                                    id: sub.id,
                                    name: sub.name,
                                    parent: a.id,
                                    active: sub.active,
                                  ),
                                )
                              : null,
                        ),
                      if (manager && a.active)
                        TextButton.icon(
                          onPressed: () => _edit(
                            context,
                            scope,
                            s,
                            'inventory_sub_areas',
                            parent: a.id,
                          ),
                          icon: const Icon(Icons.add),
                          label: const Text('Add sub-area'),
                        ),
                    ],
                  ),
                inventoryHeading(context, 'Organization categories'),
                if (!orgAdmin)
                  const Text(
                    'Organization owners and admins can configure categories.',
                  ),
                if (orgAdmin)
                  Align(
                    alignment: Alignment.centerLeft,
                    child: OutlinedButton.icon(
                      onPressed: () => _edit(
                        context,
                        scope,
                        s,
                        'inventory_categories',
                      ),
                      icon: const Icon(Icons.add),
                      label: const Text('Add category'),
                    ),
                  ),
                for (final c in s.categories)
                  ExpansionTile(
                    tilePadding: EdgeInsets.zero,
                    title: Text('${c.name}${c.active ? '' : ' · Inactive'}'),
                    subtitle: Text(c.group),
                    trailing: orgAdmin
                        ? IconButton(
                            tooltip: 'Edit ${c.name}',
                            icon: const Icon(Icons.edit_outlined),
                            onPressed: () => _edit(
                              context,
                              scope,
                              s,
                              'inventory_categories',
                              id: c.id,
                              name: c.name,
                              group: c.group,
                              active: c.active,
                            ),
                          )
                        : null,
                    children: [
                      for (final sub in s.subcategories
                          .where((sub) => sub.parentId == c.id))
                        ListTile(
                          title: Text(
                            '${sub.name}${sub.active ? '' : ' · Inactive'}',
                          ),
                          trailing: orgAdmin
                              ? IconButton(
                                  tooltip: 'Edit ${sub.name}',
                                  icon: const Icon(Icons.edit_outlined),
                                  onPressed: () => _edit(
                                    context,
                                    scope,
                                    s,
                                    'inventory_subcategories',
                                    id: sub.id,
                                    name: sub.name,
                                    parent: c.id,
                                    active: sub.active,
                                  ),
                                )
                              : null,
                        ),
                      if (orgAdmin && c.active)
                        TextButton.icon(
                          onPressed: () => _edit(
                            context,
                            scope,
                            s,
                            'inventory_subcategories',
                            parent: c.id,
                          ),
                          icon: const Icon(Icons.add),
                          label: const Text('Add subcategory'),
                        ),
                    ],
                  ),
              ],
            ),
          ),
    );
  }

  Future<void> _edit(
    BuildContext context,
    InventoryScope scope,
    InventorySnapshot snapshot,
    String table, {
    String? id,
    String? name,
    String? parent,
    String? group,
    bool active = true,
  }) =>
      showDialog<void>(
        context: context,
        builder: (_) => _MetadataEditor(
          scope: scope,
          table: table,
          id: id,
          name: name,
          parent: parent,
          group: group,
          active: active,
        ),
      );
}

class _MetadataEditor extends ConsumerStatefulWidget {
  const _MetadataEditor({
    required this.scope,
    required this.table,
    this.id,
    this.name,
    this.parent,
    this.group,
    required this.active,
  });
  final InventoryScope scope;
  final String table;
  final String? id, name, parent, group;
  final bool active;
  @override
  ConsumerState<_MetadataEditor> createState() => _MetadataState();
}

class _MetadataState extends ConsumerState<_MetadataEditor> {
  final form = GlobalKey<FormState>();
  late final name = TextEditingController(text: widget.name);
  late String group = widget.group ?? 'Beverage';
  late bool active = widget.active;
  bool busy = false;
  String? error;
  late final String? userId = ref.read(currentUserIdProvider);
  @override
  void dispose() {
    name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(
            '${widget.id == null ? 'Add' : 'Edit'} ${switch (widget.table) {
          'inventory_areas' => 'area',
          'inventory_sub_areas' => 'sub-area',
          'inventory_categories' => 'category',
          _ => 'subcategory'
        }}'),
        content: SizedBox(
          width: 440,
          child: Form(
            key: form,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextFormField(
                  controller: name,
                  maxLength: 100,
                  decoration: const InputDecoration(labelText: 'Name'),
                  validator: (v) =>
                      v == null || v.trim().isEmpty ? 'Enter a name' : null,
                ),
                if (widget.table == 'inventory_categories')
                  DropdownButtonFormField<String>(
                    initialValue: group,
                    decoration: const InputDecoration(labelText: 'Group'),
                    items: [
                      for (final g in inventoryGroups.skip(1))
                        DropdownMenuItem(value: g, child: Text(g)),
                    ],
                    onChanged: (v) => setState(() => group = v ?? 'Beverage'),
                  ),
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Active'),
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
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy ? null : _save,
            child: Text(busy ? 'Saving…' : 'Save'),
          ),
        ],
      );
  Future<void> _save() async {
    if (!form.currentState!.validate()) return;
    if (widget.active &&
        !active &&
        !await confirmInventory(
          context,
          'Make inactive?',
          'Existing records remain. This choice will be excluded from new inventory setup and counts.',
        )) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      assertInventoryScope(ref, widget.scope, userId);
      await ref.read(inventoryRepositoryProvider).saveMetadata(
            widget.table,
            {
              'name': name.text.trim(),
              'is_active': active,
              if (widget.id == null)
                'organization_id': widget.scope.organizationId,
              if (widget.id == null &&
                  {'inventory_areas', 'inventory_sub_areas'}
                      .contains(widget.table))
                'venue_id': widget.scope.venueId,
              if (widget.table == 'inventory_categories')
                'inventory_group': group,
              if (widget.id == null &&
                  widget.table == 'inventory_subcategories')
                'category_id': widget.parent,
              if (widget.id == null && widget.table == 'inventory_sub_areas')
                'area_id': widget.parent,
            },
            id: widget.id,
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
