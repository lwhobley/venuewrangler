import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_providers.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/status_chip.dart';
import '../../venues/application/venues_providers.dart';
import '../application/inventory_providers.dart';
import '../domain/inventory_v2.dart';
import 'inventory_widgets.dart';

Future<void> startInventoryCount(
  BuildContext context,
  WidgetRef ref,
  InventoryScope scope,
) async {
  final snapshot = ref.read(inventorySnapshotProvider(scope)).valueOrNull;
  if (snapshot == null) return;
  await showDialog<void>(
    context: context,
    builder: (_) => _StartCount(scope: scope, snapshot: snapshot),
  );
}

class _StartCount extends ConsumerStatefulWidget {
  const _StartCount({required this.scope, required this.snapshot});
  final InventoryScope scope;
  final InventorySnapshot snapshot;
  @override
  ConsumerState<_StartCount> createState() => _StartCountState();
}

class _StartCountState extends ConsumerState<_StartCount> {
  String type = 'full';
  String? area, category, subcategory, error;
  bool busy = false;
  final notes = TextEditingController();
  late final String? userId = ref.read(currentUserIdProvider);
  @override
  void dispose() {
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: const Text('Start physical count'),
        content: SizedBox(
          width: 480,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                SegmentedButton<String>(
                  segments: const [
                    ButtonSegment(value: 'full', label: Text('Full count')),
                    ButtonSegment(
                      value: 'partial',
                      label: Text('Partial count'),
                    ),
                  ],
                  selected: {
                    type,
                  },
                  onSelectionChanged:
                      busy ? null : (v) => setState(() => type = v.single),
                ),
                const SizedBox(height: 16),
                Text(
                  type == 'full'
                      ? 'Count every stock position in the selected scope.'
                      : 'Count only what you enter. Blank positions keep their current stock.',
                ),
                const SizedBox(height: 16),
                _choice(
                  'Area',
                  area,
                  widget.snapshot.areas
                      .where((a) => a.active)
                      .map((a) => (a.id, a.name))
                      .toList(),
                  (v) => setState(() => area = v),
                ),
                const SizedBox(height: 12),
                _choice(
                  'Category',
                  category,
                  widget.snapshot.categories
                      .where((a) => a.active)
                      .map((a) => (a.id, a.name))
                      .toList(),
                  (v) => setState(() {
                    category = v;
                    subcategory = null;
                  }),
                ),
                const SizedBox(height: 12),
                _choice(
                  'Subcategory',
                  subcategory,
                  widget.snapshot.subcategories
                      .where(
                        (a) =>
                            a.active &&
                            (category == null || a.parentId == category),
                      )
                      .map((a) => (a.id, a.name))
                      .toList(),
                  (v) => setState(() => subcategory = v),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notes,
                  decoration:
                      const InputDecoration(labelText: 'Notes (optional)'),
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
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: busy ? null : _start,
            child: Text(busy ? 'Starting…' : 'Start count'),
          ),
        ],
      );
  Widget _choice(
    String label,
    String? value,
    List<(String, String)> options,
    ValueChanged<String?> changed,
  ) =>
      DropdownButtonFormField<String>(
        key: ValueKey('$label:$value'),
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label),
        items: [
          const DropdownMenuItem<String>(value: null, child: Text('All')),
          for (final o in options)
            DropdownMenuItem(value: o.$1, child: Text(o.$2)),
        ],
        onChanged: busy ? null : changed,
      );
  Future<void> _start() async {
    setState(() {
      busy = true;
      error = null;
    });
    try {
      assertInventoryScope(ref, widget.scope, userId);
      final id = await ref.read(inventoryRepositoryProvider).startCount(
            widget.scope.venueId,
            type: type,
            areaId: area,
            categoryId: category,
            subcategoryId: subcategory,
            notes: notes.text.trim(),
          );
      if (!mounted) return;
      refreshInventory(ref, widget.scope);
      final count = InventoryCount.fromJson({
        'id': id,
        'status': 'draft',
        'count_type': type,
        'area_id': area,
        'category_id': category,
        'started_at': DateTime.now().toIso8601String(),
      });
      final navigator = Navigator.of(context);
      navigator.pop();
      navigator.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              InventoryCountScreen(scope: widget.scope, count: count),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = inventoryError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}

class InventoryCountScreen extends ConsumerStatefulWidget {
  const InventoryCountScreen({
    super.key,
    required this.scope,
    required this.count,
  });
  final InventoryScope scope;
  final InventoryCount count;
  @override
  ConsumerState<InventoryCountScreen> createState() => _CountState();
}

class _CountState extends ConsumerState<InventoryCountScreen> {
  final controllers = <String, TextEditingController>{};
  final focus = <String, FocusNode>{};
  late final String? userId = ref.read(currentUserIdProvider);
  bool busy = false, dirty = false;
  String? error, closed;
  @override
  void dispose() {
    for (final c in controllers.values) {
      c.dispose();
    }
    for (final n in focus.values) {
      n.dispose();
    }
    super.dispose();
  }

  String get status => closed ?? widget.count.status;
  bool get open => status == 'draft' || status == 'in_progress';
  @override
  Widget build(BuildContext context) {
    final lines = ref.watch(inventoryCountLinesProvider(widget.count.id));
    final manager =
        ref.watch(canManageActiveVenueProvider).valueOrNull ?? false;
    final savedCount = ref
            .watch(inventorySnapshotProvider(widget.scope))
            .valueOrNull
            ?.counts
            .where((c) => c.id == widget.count.id)
            .firstOrNull ??
        widget.count;
    return PopScope(
      canPop: !dirty && !busy,
      onPopInvokedWithResult: (didPop, result) async {
        if (didPop || busy) return;
        if (await confirmInventory(
              context,
              'Leave unsaved count?',
              'Your saved progress stays available. Unsaved entries will be discarded.',
            ) &&
            mounted) {
          setState(() => dirty = false);
          if (context.mounted) Navigator.pop(context);
        }
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            open
                ? 'Physical count'
                : 'Count ${status == 'completed' ? 'summary' : 'history'}',
          ),
          actions: [
            if (open && manager)
              IconButton(
                tooltip: 'Cancel this count',
                icon: const Icon(Icons.close),
                onPressed: busy ? null : () => _cancel(),
              ),
          ],
        ),
        body: lines.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, __) => InventoryLoadError(
            retry: () => ref.invalidate(
              inventoryCountLinesProvider(widget.count.id),
            ),
          ),
          data: (rows) {
            for (final r in rows) {
              controllers.putIfAbsent(
                r.id,
                () => TextEditingController(text: r.counted),
              );
              focus.putIfAbsent(r.id, FocusNode.new);
              if (status == 'cancelled' &&
                  controllers[r.id]!.text != (r.counted ?? '')) {
                controllers[r.id]!.text = r.counted ?? '';
              }
            }
            final counted = rows
                .where((r) => controllers[r.id]!.text.trim().isNotEmpty)
                .length;
            final knownVariance =
                rows.where((r) => r.variance != null && r.cost != null).fold(
                      BigInt.zero,
                      (v, r) => v + inventoryValue(r.variance, r.cost),
                    );
            return Column(
              children: [
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.all(16),
                  color: Theme.of(context).colorScheme.surfaceContainerLow,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        open
                            ? '$counted / ${rows.length} counted'
                            : status.toUpperCase(),
                        style: Theme.of(context).textTheme.titleLarge,
                      ),
                      const SizedBox(height: 8),
                      if (open)
                        LinearProgressIndicator(
                          value: rows.isEmpty ? 0 : counted / rows.length,
                        ),
                      const SizedBox(height: 8),
                      if (status == 'cancelled')
                        const Text(
                          'This count was cancelled. Entries were not applied to stock.',
                        ),
                      Text(
                        open
                            ? (widget.count.type == 'partial'
                                ? 'Partial count • blank rows stay unchanged'
                                : 'Full count • enter every location')
                            : 'Known variance value: ${inventoryMoney(knownVariance)}',
                      ),
                      if (!open &&
                          rows.any(
                            (r) =>
                                r.counted != null &&
                                (r.previous == null || r.cost == null),
                          ))
                        const Text(
                          'Some variance values are unknown because an opening quantity or cost was missing.',
                        ),
                      if (!open && savedCount.completedAt != null)
                        Text(
                          '${status == 'cancelled' ? 'Cancelled' : 'Completed'} ${MaterialLocalizations.of(context).formatFullDate(savedCount.completedAt!.toLocal())} at ${MaterialLocalizations.of(context).formatTimeOfDay(TimeOfDay.fromDateTime(savedCount.completedAt!.toLocal()))} • ${savedCount.completedByName ?? (savedCount.completedBy == null ? 'Former team member' : 'Team member')}',
                        ),
                      if (error != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
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
                Expanded(
                  child: ListView.builder(
                    padding: const EdgeInsets.all(16),
                    itemCount: rows.length,
                    itemBuilder: (context, index) {
                      final r = rows[index];
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 20),
                        child: LayoutBuilder(
                          builder: (context, size) {
                            final description = Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  r.location,
                                  style:
                                      Theme.of(context).textTheme.labelMedium,
                                ),
                                Text(
                                  r.name,
                                  style:
                                      Theme.of(context).textTheme.titleMedium,
                                ),
                                Text(
                                  '${r.size ?? ''}${r.size == null ? '' : ' • '}${r.unit}',
                                ),
                                Text(
                                  'Previous: ${r.previous ?? 'Unknown'}',
                                ),
                                if (open && controllers[r.id]!.text.isEmpty)
                                  const Padding(
                                    padding: EdgeInsets.only(top: 6),
                                    child: StatusChip(
                                      label: 'Not counted',
                                      tone: Tone.neutral,
                                      dense: true,
                                    ),
                                  ),
                                if (!open)
                                  Text(
                                    r.counted == null
                                        ? 'Not counted • stock unchanged'
                                        : 'Counted: ${r.counted} • Variance: ${r.variance ?? 'Unknown'} ${r.unit}',
                                  ),
                                if (!open &&
                                    r.variance != null &&
                                    r.cost != null)
                                  Text(
                                    inventoryMoney(
                                      inventoryValue(
                                        r.variance,
                                        r.cost,
                                      ),
                                    ),
                                  ),
                              ],
                            );
                            final input = SizedBox(
                              width:
                                  size.maxWidth > 500 ? 170 : double.infinity,
                              child: TextField(
                                controller: controllers[r.id],
                                focusNode: focus[r.id],
                                enabled: open && manager && !busy,
                                keyboardType:
                                    const TextInputType.numberWithOptions(
                                  decimal: true,
                                ),
                                textInputAction: index == rows.length - 1
                                    ? TextInputAction.done
                                    : TextInputAction.next,
                                decoration: InputDecoration(
                                  labelText: 'Count · ${r.unit}',
                                  hintText: 'Not counted',
                                ),
                                style:
                                    Theme.of(context).textTheme.headlineSmall,
                                onChanged: (_) => setState(() => dirty = true),
                                onSubmitted: (_) {
                                  if (index < rows.length - 1) {
                                    focus[rows[index + 1].id]!.requestFocus();
                                  }
                                },
                              ),
                            );
                            return size.maxWidth > 500
                                ? Row(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Expanded(child: description),
                                      const SizedBox(width: 16),
                                      input,
                                    ],
                                  )
                                : Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      description,
                                      const SizedBox(height: 10),
                                      input,
                                    ],
                                  );
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
            );
          },
        ),
        bottomNavigationBar: open && manager
            ? SafeArea(
                top: false,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    children: [
                      Expanded(
                        child: OutlinedButton(
                          onPressed: busy ? null : () => _save(false),
                          child: const Text('Save progress'),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: FilledButton(
                          onPressed: busy ? null : () => _save(true),
                          child: Text(
                            busy ? 'Saving…' : 'Complete count',
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              )
            : null,
      ),
    );
  }

  Future<void> _save(bool complete) async {
    final rows =
        ref.read(inventoryCountLinesProvider(widget.count.id)).valueOrNull;
    if (rows == null) return;
    final values = <Map<String, dynamic>>[];
    for (final r in rows) {
      final text = controllers[r.id]!.text.trim();
      final problem = inventoryNumberValidation(text, optional: true);
      if (problem != null) {
        setState(() => error = '${r.name}: $problem');
        return;
      }
      values.add({'id': r.id, 'quantity': text.isEmpty ? null : text});
    }
    if (complete &&
        !await confirmInventory(
          context,
          'Complete this count?',
          'Counted quantities will replace stock for these locations and create permanent history.',
        )) {
      return;
    }
    setState(() {
      busy = true;
      error = null;
    });
    try {
      assertInventoryScope(ref, widget.scope, userId);
      await ref
          .read(inventoryRepositoryProvider)
          .saveCount(widget.count.id, values, complete: complete);
      if (!mounted) return;
      setState(() {
        dirty = false;
        if (complete) closed = 'completed';
      });
      ref.invalidate(inventoryCountLinesProvider(widget.count.id));
      refreshInventory(ref, widget.scope);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            complete
                ? 'Count completed. Stock and history updated.'
                : 'Count progress saved.',
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => error = inventoryError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _cancel() async {
    if (!await confirmInventory(
      context,
      'Cancel this count?',
      'Saved entries will remain in count history. Stock will not change.',
    )) {
      return;
    }
    setState(() => busy = true);
    try {
      assertInventoryScope(ref, widget.scope, userId);
      await ref
          .read(inventoryRepositoryProvider)
          .saveCount(widget.count.id, const [], cancel: true);
      if (!mounted) return;
      setState(() {
        dirty = false;
        closed = 'cancelled';
      });
      refreshInventory(ref, widget.scope);
    } catch (e) {
      if (mounted) setState(() => error = inventoryError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }
}
