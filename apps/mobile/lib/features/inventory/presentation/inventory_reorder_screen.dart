import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/ops_colors.dart';
import '../../ai/application/ai_providers.dart';
import '../application/inventory_providers.dart';
import '../domain/inventory_v2.dart';
import '../domain/reorder_planner.dart';
import 'inventory_widgets.dart';

/// "Suggest reorder". Opens on the deterministic below-par list (always available, no AI), and
/// "Suggest with AI" replaces it with a draft that also weighs recent use and flags unusual
/// jumps. Either way the lines are editable, the estimated cost is computed here from unit
/// costs, and the list can be copied as text. The app has no purchase-order table, so nothing is
/// ever ordered or saved from here.
class InventoryReorderScreen extends ConsumerStatefulWidget {
  const InventoryReorderScreen({
    super.key,
    required this.scope,
    required this.venueName,
  });

  final InventoryScope scope;
  final String venueName;

  @override
  ConsumerState<InventoryReorderScreen> createState() =>
      _InventoryReorderScreenState();
}

class _InventoryReorderScreenState
    extends ConsumerState<InventoryReorderScreen> {
  List<ReorderLine>? _lines;
  List<ReorderFlag> _flags = const [];
  ReorderSource _source = ReorderSource.belowPar;
  // Bumped whenever the lines are replaced so the quantity fields rebuild from the new values.
  int _generation = 0;
  bool _busy = false;
  String? _error;
  String? _notice;

  Future<void> _askAi(List<ReorderItem> items) async {
    final input = buildReorderInput(items, today: DateTime.now());
    if (input.sentKeys.isEmpty) {
      setState(
        () => _error = 'Nothing is low or in use, so there is '
            'nothing to ask about.',
      );
      return;
    }
    if (input.tooLarge) {
      setState(() => _error = 'There are too many items to send at once.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final result = await ref.read(aiRepositoryProvider).suggestReorder(
            venueId: widget.scope.venueId,
            context: input.text,
          );
      if (!mounted) return;
      final draft = buildReorderDraft(result, items, sentKeys: input.sentKeys);
      setState(() {
        _busy = false;
        _flags = draft.flags;
        if (draft.lines.isEmpty) {
          _error = 'The assistant did not suggest ordering anything. '
              'The below-par list is still available.';
          return;
        }
        _lines = draft.lines;
        _source = ReorderSource.ai;
        _generation++;
        _notice = [
          if (draft.dropped > 0)
            '${draft.dropped} suggested ${draft.dropped == 1 ? 'line was' : 'lines were'} '
                'left out (unknown item or no quantity).',
          if (input.omitted > 0)
            '${input.omitted} lower-priority items were not sent.',
        ].join(' ');
      });
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = error.message;
      });
    }
  }

  void _useBelowPar(List<ReorderItem> items) {
    setState(() {
      _lines = belowParLines(items);
      _flags = [
        for (final i in items)
          if (i.varianceNote != null)
            ReorderFlag(item: i, note: i.varianceNote!, fromAi: false),
      ];
      _source = ReorderSource.belowPar;
      _generation++;
      _error = null;
      _notice = null;
    });
  }

  Future<void> _copy(List<ReorderLine> lines) async {
    final text = reorderAsText(
      lines,
      venueName: widget.venueName,
      today: DateTime.now(),
    );
    await Clipboard.setData(ClipboardData(text: text));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Reorder list copied.')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = ref.watch(inventorySnapshotProvider(widget.scope));
    return Scaffold(
      appBar: AppBar(title: const Text('Suggest reorder')),
      body: snapshot.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => InventoryLoadError(
          retry: () => ref.invalidate(inventorySnapshotProvider(widget.scope)),
        ),
        data: (s) {
          final items = reorderItemsFromSnapshot(s, now: DateTime.now());
          _lines ??= belowParLines(items);
          if (_flags.isEmpty && _source == ReorderSource.belowPar) {
            _flags = [
              for (final i in items)
                if (i.varianceNote != null)
                  ReorderFlag(item: i, note: i.varianceNote!, fromAi: false),
            ];
          }
          return _body(context, items);
        },
      ),
    );
  }

  Widget _body(BuildContext context, List<ReorderItem> items) {
    final theme = Theme.of(context);
    final lines = _lines ?? const <ReorderLine>[];
    final total = reorderTotal(lines);
    final noPar = itemsWithoutPar(items);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          _source == ReorderSource.ai
              ? 'AI draft. Check every quantity before ordering. Nothing is '
                  'ordered or saved from here.'
              : 'Items below their par level, to bring each back to par. '
                  'Nothing is ordered or saved from here.',
          style: theme.textTheme.bodyMedium,
        ),
        if (noPar > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '$noPar ${noPar == 1 ? 'item has' : 'items have'} no par level '
              'set, so ${noPar == 1 ? 'it is' : 'they are'} not checked here. '
              'Use is estimated from count decreases, waste and adjustments in '
              'the last 30 days, because the app has no sales feed.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _busy ? null : () => _askAi(items),
              icon: _busy
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.auto_awesome_outlined),
              label: const Text('Suggest with AI'),
            ),
            if (_source == ReorderSource.ai)
              OutlinedButton(
                onPressed: _busy ? null : () => _useBelowPar(items),
                child: const Text('Back to below-par list'),
              ),
          ],
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: context.ops.danger.fg),
            ),
          ),
        if (_notice != null && _notice!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text(
              _notice!,
              style: TextStyle(color: context.ops.warning.fg),
            ),
          ),
        if (_flags.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Unusual use', style: theme.textTheme.titleMedium),
          for (final f in _flags)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(
                    Icons.warning_amber_rounded,
                    size: 16,
                    color: context.ops.warning.fg,
                  ),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '${f.item.item.name}: ${f.note}'
                      '${f.fromAi ? ' (AI)' : ''}',
                      style: theme.textTheme.bodySmall,
                    ),
                  ),
                ],
              ),
            ),
        ],
        const SizedBox(height: 16),
        Text('Order list', style: theme.textTheme.titleMedium),
        if (lines.isEmpty)
          const InventoryEmpty('Nothing is below par. Nothing to order.'),
        for (final (index, line) in lines.indexed)
          _LineCard(
            key: ValueKey('$_generation-${line.item.item.id}'),
            line: line,
            onQuantity: (value) => setState(
              () => _lines = [
                for (final (i, l) in lines.indexed)
                  i == index ? l.withQuantity(value) : l,
              ],
            ),
            onRemove: () => setState(
              () => _lines = [
                for (final (i, l) in lines.indexed)
                  if (i != index) l,
              ],
            ),
          ),
        if (lines.isNotEmpty) ...[
          const SizedBox(height: 8),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerLow,
              border: Border.all(color: context.ops.panelBorder),
              borderRadius: BorderRadius.circular(AppRadii.card),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Estimated total ${inventoryMoney(total.total)}',
                  style: theme.textTheme.titleMedium,
                ),
                Text(
                  total.unpriced == 0
                      ? 'Computed from each item’s unit cost.'
                      : '${total.unpriced} ${total.unpriced == 1 ? 'line has' : 'lines have'} '
                          'no unit cost or a quantity that can’t be read, '
                          'so ${total.unpriced == 1 ? 'it is' : 'they are'} not counted.',
                  style: theme.textTheme.bodySmall,
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: () => _copy(lines),
            icon: const Icon(Icons.copy_outlined),
            label: const Text('Copy as text'),
          ),
        ],
      ],
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({
    super.key,
    required this.line,
    required this.onQuantity,
    required this.onRemove,
  });

  final ReorderLine line;
  final ValueChanged<String> onQuantity;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final item = line.item.item;
    final cost = line.cost;
    final unreadable = line.parsedQuantity == null;
    return Card(
      margin: const EdgeInsets.only(top: 8),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(item.name, style: theme.textTheme.titleSmall),
                  if ((item.supplier ?? '').trim().isNotEmpty)
                    Text(
                      item.supplier!.trim(),
                      style: theme.textTheme.bodySmall,
                    ),
                  if (line.reason.isNotEmpty)
                    Text(line.reason, style: theme.textTheme.bodySmall),
                  if (line.flag != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        line.flag!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: context.ops.warning.fg,
                        ),
                      ),
                    ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      SizedBox(
                        width: 110,
                        child: TextFormField(
                          initialValue: line.quantity,
                          keyboardType: const TextInputType.numberWithOptions(
                            decimal: true,
                          ),
                          decoration: InputDecoration(
                            labelText: 'Quantity',
                            errorText: unreadable ? 'Number' : null,
                          ),
                          onChanged: onQuantity,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          '${item.displayUnit} · '
                          '${cost == null ? 'no cost' : inventoryMoney(cost)}',
                          style: theme.textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Remove from list',
              icon: const Icon(Icons.close),
              onPressed: onRemove,
            ),
          ],
        ),
      ),
    );
  }
}
