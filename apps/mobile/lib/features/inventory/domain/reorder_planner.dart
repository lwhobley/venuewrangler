import 'dart:convert';

import '../../ai/domain/ai_models.dart';
import 'inventory_item.dart';
import 'inventory_v2.dart';

/// "Suggest reorder" (`inventory_reorder`). The data sent to the assistant is gathered here
/// from the inventory snapshot, the draft order is read back against it, and every figure shown
/// (shortfall, estimated cost) is computed here: the assistant only proposes item keys,
/// quantities and reasons. Nothing in this file writes anything; the app has no purchase-order
/// table, so the result is an editable list to copy.
///
/// Par levels exist per stock position (`inventory_stock.par_level`); an item's par is the sum of
/// its positions' pars and its shortfall is the sum of the positions' shortages, the same figures
/// the Replenish tab shows. There is no sales feed, so "used" is estimated from the item's
/// history: count decreases, waste and negative adjustments (transfers move stock, they do not
/// use it).

const reorderRecentDays = 14;
const reorderPriorDays = 16;
const reorderMaxInputChars = 18000;
const reorderMaxItems = 120;

/// Recent use per day at least this many times the earlier rate counts as a jump.
const reorderVarianceRatio = 1.5;

double _units(BigInt v) => v.toDouble() / 10000;

BigInt? _safeDecimal(Object? value, {int scale = 4}) {
  try {
    return inventoryDecimal(value, scale: scale);
  } on FormatException {
    return null;
  }
}

String _plain(num n) {
  final fixed = n.toStringAsFixed(4);
  return fixed.contains('.')
      ? fixed.replaceFirst(RegExp(r'0+$'), '').replaceFirst(RegExp(r'\.$'), '')
      : fixed;
}

/// One inventory item as the planner sees it, with the short key the assistant answers with.
class ReorderItem {
  const ReorderItem({
    required this.key,
    required this.item,
    required this.onHand,
    required this.par,
    required this.shortfall,
    required this.usedRecent,
    required this.usedPrior,
    required this.receivedRecent,
  });

  final String key;
  final InventoryItem item;

  /// Total on hand across active positions (uncounted positions count as zero).
  final BigInt onHand;

  /// Total par across positions that have one; null when none does.
  final BigInt? par;
  final BigInt shortfall;
  final BigInt usedRecent;
  final BigInt usedPrior;
  final BigInt receivedRecent;

  bool get hasPar => par != null;
  bool get belowPar => shortfall > BigInt.zero;

  /// Use per day in the last [reorderRecentDays] days against the [reorderPriorDays] before,
  /// as a ratio; null when there is nothing earlier to compare with.
  double? get usageRatio {
    final prior = _units(usedPrior) / reorderPriorDays;
    if (prior <= 0) return null;
    return (_units(usedRecent) / reorderRecentDays) / prior;
  }

  /// A deterministic note when use jumped well past the earlier rate, else null.
  String? get varianceNote {
    final ratio = usageRatio;
    if (ratio == null || ratio < reorderVarianceRatio) return null;
    return 'Use is running ${ratio.toStringAsFixed(1)}x the earlier rate '
        '(${inventoryQuantity(usedRecent)} in $reorderRecentDays days vs '
        '${inventoryQuantity(usedPrior)} in the $reorderPriorDays before).';
  }
}

/// The active items that have stock positions, with usage from the last 30 days of history.
/// Ordered by shortfall (largest first), then by recent use, then name.
List<ReorderItem> reorderItemsFromSnapshot(
  InventorySnapshot s, {
  required DateTime now,
}) {
  final recentFrom = now.subtract(const Duration(days: reorderRecentDays));
  final priorFrom = recentFrom.subtract(const Duration(days: reorderPriorDays));
  final positionsByItem = <String, List<InventoryStock>>{};
  for (final p in s.activePositions) {
    positionsByItem.putIfAbsent(p.itemId, () => []).add(p);
  }

  final usedRecent = <String, BigInt>{};
  final usedPrior = <String, BigInt>{};
  final received = <String, BigInt>{};
  for (final h in s.history) {
    final id = h.itemId;
    if (id == null || h.createdAt.isBefore(priorFrom)) continue;
    final change = _safeDecimal(h.change);
    if (change == null) continue;
    final recent = !h.createdAt.isBefore(recentFrom);
    if (h.action == 'RECEIVE' && change > BigInt.zero && recent) {
      received[id] = (received[id] ?? BigInt.zero) + change;
    } else if ((h.action == 'COUNT' ||
            h.action == 'WASTE' ||
            h.action == 'ADJUSTMENT') &&
        change < BigInt.zero) {
      final into = recent ? usedRecent : usedPrior;
      into[id] = (into[id] ?? BigInt.zero) - change;
    }
  }

  final items = <ReorderItem>[];
  for (final item in s.items.where((i) => i.active)) {
    final positions = positionsByItem[item.id];
    if (positions == null || positions.isEmpty) continue;
    var onHand = BigInt.zero;
    BigInt? par;
    var shortfall = BigInt.zero;
    for (final p in positions) {
      onHand += _safeDecimal(p.quantity) ?? BigInt.zero;
      final positionPar = p.par == null ? null : _safeDecimal(p.par);
      if (positionPar != null) par = (par ?? BigInt.zero) + positionPar;
      shortfall += p.shortage;
    }
    items.add(
      ReorderItem(
        key: '',
        item: item,
        onHand: onHand,
        par: par,
        shortfall: shortfall,
        usedRecent: usedRecent[item.id] ?? BigInt.zero,
        usedPrior: usedPrior[item.id] ?? BigInt.zero,
        receivedRecent: received[item.id] ?? BigInt.zero,
      ),
    );
  }
  items.sort((a, b) {
    final byShortfall = b.shortfall.compareTo(a.shortfall);
    if (byShortfall != 0) return byShortfall;
    final byUse = b.usedRecent.compareTo(a.usedRecent);
    if (byUse != 0) return byUse;
    return a.item.name.toLowerCase().compareTo(b.item.name.toLowerCase());
  });
  return [
    for (final (i, e) in items.indexed)
      ReorderItem(
        key: 'item_${i + 1}',
        item: e.item,
        onHand: e.onHand,
        par: e.par,
        shortfall: e.shortfall,
        usedRecent: e.usedRecent,
        usedPrior: e.usedPrior,
        receivedRecent: e.receivedRecent,
      ),
  ];
}

/// What was gathered for one request.
class ReorderInput {
  const ReorderInput({
    required this.text,
    required this.sentKeys,
    required this.omitted,
    required this.tooLarge,
  });

  final String text;

  /// The keys that were actually sent (the assistant can only be answered for these).
  final Set<String> sentKeys;

  /// Items left out to keep the request small.
  final int omitted;
  final bool tooLarge;
}

String _clip(String s, int max) {
  final t = s.replaceAll(RegExp(r'\s+'), ' ').trim();
  return t.length > max ? t.substring(0, max) : t;
}

/// The compact JSON sent to the assistant. Data included per item: short key, name, count
/// unit, quantity on hand, total par, shortfall, unit cost, supplier name, and use/receipts over
/// the last 14 days and the 16 before. Only items that are below par, out, or used recently
/// are sent. Never sent: ids, notes, people, locations.
ReorderInput buildReorderInput(
  List<ReorderItem> items, {
  required DateTime today,
}) {
  final relevant = [
    for (final i in items)
      if (i.belowPar || i.usedRecent > BigInt.zero || i.onHand <= BigInt.zero)
        i,
  ];
  Map<String, Object?> row(ReorderItem i) => {
        'key': i.key,
        'name': _clip(i.item.name, 60),
        'unit': _clip(i.item.displayUnit, 20),
        'on_hand': _units(i.onHand),
        'par': i.par == null ? null : _units(i.par!),
        'shortfall_to_par': _units(i.shortfall),
        'unit_cost_usd': i.item.unitCostUsd,
        'supplier':
            i.item.supplier == null ? null : _clip(i.item.supplier!, 40),
        'used_recent': _units(i.usedRecent),
        'used_prior': _units(i.usedPrior),
        'received_recent': _units(i.receivedRecent),
      };
  String encode(List<ReorderItem> rows) => jsonEncode({
        'today':
            '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}',
        'windows_days': {
          'recent': reorderRecentDays,
          'prior': reorderPriorDays,
        },
        'usage_note': 'used = count decreases + waste + negative adjustments '
            '(there is no sales feed); quantities are in each item count unit',
        'items': [for (final i in rows) row(i)],
      });

  var kept = relevant.take(reorderMaxItems).toList();
  var text = encode(kept);
  while (text.length > reorderMaxInputChars && kept.isNotEmpty) {
    kept = kept.sublist(0, (kept.length * 3) ~/ 4);
    text = encode(kept);
  }
  return ReorderInput(
    text: text,
    sentKeys: {for (final i in kept) i.key},
    omitted: relevant.length - kept.length,
    tooLarge: text.length > reorderMaxInputChars,
  );
}

enum ReorderSource { belowPar, ai }

/// One editable line of a draft order. [quantity] is the text in the field, a decimal in the
/// item's count unit (up to 4 places); an unreadable one is reported by [parsedQuantity].
class ReorderLine {
  const ReorderLine({
    required this.item,
    required this.quantity,
    required this.reason,
    required this.source,
    this.flag,
  });

  final ReorderItem item;
  final String quantity;
  final String reason;
  final ReorderSource source;

  /// Variance note for this item, from the assistant or the deterministic check.
  final String? flag;

  ReorderLine withQuantity(String value) => ReorderLine(
        item: item,
        quantity: value,
        reason: reason,
        source: source,
        flag: flag,
      );

  /// The quantity as fixed-point units, or null when it is not a non-negative decimal.
  BigInt? get parsedQuantity {
    final text = quantity.trim();
    if (text.isEmpty) return null;
    final value = _safeDecimal(text);
    if (value == null || value.isNegative) return null;
    return value;
  }

  /// Cost of this line, or null when the quantity is unreadable or the item has no unit cost.
  BigInt? get cost {
    final qty = parsedQuantity;
    final unitCost = item.item.unitCostUsd;
    if (qty == null || unitCost == null) return null;
    final text = unitCost.toString();
    if (_safeDecimal(text, scale: 2) == null) return null;
    return inventoryValue(inventoryQuantity(qty), text);
  }
}

/// The deterministic list: every item below par, ordered to buy the shortfall. This is what the
/// screen shows before (or without) the assistant.
List<ReorderLine> belowParLines(List<ReorderItem> items) => [
      for (final i in items)
        if (i.belowPar)
          ReorderLine(
            item: i,
            quantity: inventoryQuantity(i.shortfall),
            reason: 'Below par: ${inventoryQuantity(i.onHand)} on hand, '
                'par ${inventoryQuantity(i.par ?? BigInt.zero)}',
            source: ReorderSource.belowPar,
            flag: i.varianceNote,
          ),
    ];

/// Items with no par level set anywhere: "below par" cannot be worked out for them.
int itemsWithoutPar(List<ReorderItem> items) =>
    items.where((i) => !i.hasPar).length;

/// A variance finding to show, for an item that may or may not be on the order.
class ReorderFlag {
  const ReorderFlag({
    required this.item,
    required this.note,
    required this.fromAi,
  });

  final ReorderItem item;
  final String note;
  final bool fromAi;
}

class ReorderDraft {
  const ReorderDraft({
    required this.lines,
    required this.flags,
    required this.dropped,
  });

  final List<ReorderLine> lines;
  final List<ReorderFlag> flags;

  /// Answer rows that named an unknown item, repeated one, or had no usable quantity.
  final int dropped;
}

/// Reads the assistant's answer against the items that were sent. Unknown or repeated keys,
/// and rows without a positive quantity, are dropped; quantities are clamped; the variance flags
/// are the assistant's plus the deterministic jump check, each item once.
ReorderDraft buildReorderDraft(
  InventoryReorderResult result,
  List<ReorderItem> items, {
  required Set<String> sentKeys,
}) {
  final byKey = {
    for (final i in items)
      if (sentKeys.contains(i.key)) i.key: i,
  };
  final flagsByKey = <String, ReorderFlag>{};
  for (final f in result.varianceFlags) {
    final item = byKey[f.itemKey.trim().toLowerCase()];
    if (item == null || f.note.isEmpty) continue;
    flagsByKey.putIfAbsent(
      item.key,
      () => ReorderFlag(item: item, note: f.note, fromAi: true),
    );
  }
  for (final item in byKey.values) {
    final note = item.varianceNote;
    if (note != null) {
      flagsByKey.putIfAbsent(
        item.key,
        () => ReorderFlag(item: item, note: note, fromAi: false),
      );
    }
  }

  final lines = <ReorderLine>[];
  final seen = <String>{};
  var dropped = 0;
  for (final o in result.orders) {
    final item = byKey[o.itemKey.trim().toLowerCase()];
    final qty = o.suggestedQuantity;
    if (item == null || qty == null || qty <= 0 || !seen.add(item.key)) {
      dropped++;
      continue;
    }
    lines.add(
      ReorderLine(
        item: item,
        quantity: _plain(qty),
        reason: o.reason,
        source: ReorderSource.ai,
        flag: flagsByKey[item.key]?.note,
      ),
    );
  }
  return ReorderDraft(
    lines: lines,
    flags: flagsByKey.values.toList(),
    dropped: dropped,
  );
}

/// Estimated total of the lines that have a readable quantity and a unit cost, and how many
/// lines could not be priced. Always computed here from unit costs.
({BigInt total, int unpriced}) reorderTotal(Iterable<ReorderLine> lines) {
  var total = BigInt.zero;
  var unpriced = 0;
  for (final l in lines) {
    final cost = l.cost;
    if (cost == null) {
      unpriced++;
    } else {
      total += cost;
    }
  }
  return (total: total, unpriced: unpriced);
}

/// Plain text of the order for pasting into a message or email, grouped by supplier.
String reorderAsText(
  Iterable<ReorderLine> lines, {
  required String venueName,
  required DateTime today,
}) {
  final usable = [
    for (final l in lines)
      if ((l.parsedQuantity ?? BigInt.zero) > BigInt.zero) l,
  ];
  final bySupplier = <String, List<ReorderLine>>{};
  for (final l in usable) {
    final supplier = (l.item.item.supplier ?? '').trim();
    bySupplier
        .putIfAbsent(supplier.isEmpty ? 'No supplier set' : supplier, () => [])
        .add(l);
  }
  final names = bySupplier.keys.toList()
    ..sort((a, b) {
      if (a == 'No supplier set') return 1;
      if (b == 'No supplier set') return -1;
      return a.toLowerCase().compareTo(b.toLowerCase());
    });
  final out = StringBuffer()
    ..writeln(
      'Reorder list - $venueName - '
      '${today.year}-${today.month.toString().padLeft(2, '0')}-${today.day.toString().padLeft(2, '0')}',
    );
  for (final name in names) {
    out
      ..writeln()
      ..writeln(name);
    for (final l in bySupplier[name]!) {
      final cost = l.cost;
      out.writeln(
        '- ${l.item.item.name}: ${inventoryQuantity(l.parsedQuantity!)} '
        '${l.item.item.displayUnit}'
        '${cost == null ? '' : ' (${inventoryMoney(cost)})'}',
      );
    }
  }
  final t = reorderTotal(usable);
  out
    ..writeln()
    ..write('Estimated total: ${inventoryMoney(t.total)}')
    ..write(
      t.unpriced == 0
          ? ''
          : ' (${t.unpriced} ${t.unpriced == 1 ? 'line has' : 'lines have'} '
              'no unit cost and ${t.unpriced == 1 ? 'is' : 'are'} not included)',
    );
  return out.toString();
}
