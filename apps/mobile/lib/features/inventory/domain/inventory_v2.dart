import 'inventory_item.dart';

const inventoryCountUnits = [
  'Bottle',
  'Case',
  'Each',
  'Pound',
  'Ounce',
  'Gallon',
  'Liter',
  'Keg',
  'Bag',
  'Box',
  'Pack',
  'Can',
  'Container',
  'Tray',
  'Dozen',
  'Custom',
];
const inventorySizeUnits = [
  'mL',
  'L',
  'oz',
  'fl oz',
  'gal',
  'lb',
  'kg',
  'g',
  'count',
];
const inventoryGroups = [
  'All',
  'Beverage',
  'Food',
  'Non-Food',
  'Uncategorized',
];
const inventoryWasteReasons = [
  'Spoilage',
  'Spill',
  'Breakage',
  'Expired',
  'Damaged',
  'Preparation Waste',
  'Other',
];

/// Fixed decimal arithmetic for quantities and money. No binary floating-point valuation.
BigInt inventoryDecimal(Object? value, {int scale = 4}) {
  if (value == null) return BigInt.zero;
  final text = value.toString();
  final match = RegExp(r'^(-?)(\d+)(?:\.(\d+))?$').firstMatch(text);
  if (match == null) throw FormatException('Use a decimal number', text);
  final fraction = match.group(3) ?? '';
  if (fraction.length > scale &&
      fraction.substring(scale).contains(RegExp('[1-9]'))) {
    throw FormatException('Use at most $scale decimal places', text);
  }
  final digits = fraction.padRight(scale, '0').substring(0, scale);
  final amount = BigInt.parse('${match.group(2)}$digits');
  return match.group(1) == '-' ? -amount : amount;
}

String inventoryQuantity(BigInt units) {
  final absolute = units.abs().toString().padLeft(5, '0');
  final whole = absolute.substring(0, absolute.length - 4);
  final decimal =
      absolute.substring(absolute.length - 4).replaceFirst(RegExp(r'0+$'), '');
  return '${units.isNegative ? '-' : ''}$whole${decimal.isEmpty ? '' : '.$decimal'}';
}

BigInt inventoryValue(Object? quantity, Object? cost) =>
    inventoryDecimal(quantity) *
    inventoryDecimal(cost, scale: 2); // millionths of a dollar

String inventoryMoney(BigInt micros) {
  final cents = (micros.abs() + BigInt.from(5000)) ~/ BigInt.from(10000);
  return '${micros.isNegative ? '-' : ''}\$${cents ~/ BigInt.from(100)}.${(cents % BigInt.from(100)).toString().padLeft(2, '0')}';
}

class InventoryCategory {
  InventoryCategory.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        group = j['inventory_group'] as String? ?? '',
        parentId = j['category_id'] as String?,
        active = j['is_active'] as bool? ?? true;
  final String id, name, group;
  final String? parentId;
  final bool active;
}

class InventoryArea {
  InventoryArea.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['name'] as String,
        parentId = j['area_id'] as String?,
        active = j['is_active'] as bool? ?? true;
  final String id, name;
  final String? parentId;
  final bool active;
}

enum InventoryStockStatus { available, low, out, unknown }

class InventoryStock {
  InventoryStock.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        itemId = j['inventory_item_id'] as String,
        areaId = j['area_id'] as String,
        subAreaId = j['sub_area_id'] as String?,
        quantity = j['quantity']?.toString(),
        par = j['par_level']?.toString();
  final String id, itemId, areaId;
  final String? subAreaId, quantity, par;
  BigInt get shortage {
    if (quantity == null || par == null) return BigInt.zero;
    final missing = inventoryDecimal(par) - inventoryDecimal(quantity);
    return missing > BigInt.zero ? missing : BigInt.zero;
  }

  InventoryStockStatus get status {
    if (quantity == null) return InventoryStockStatus.unknown;
    final q = inventoryDecimal(quantity);
    if (q <= BigInt.zero) return InventoryStockStatus.out;
    return shortage > BigInt.zero
        ? InventoryStockStatus.low
        : InventoryStockStatus.available;
  }
}

class InventoryCount {
  InventoryCount.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        status = j['status'] as String,
        type = j['count_type'] as String,
        areaId = j['area_id'] as String?,
        categoryId = j['category_id'] as String?,
        startedAt = DateTime.parse(j['started_at'] as String),
        completedAt = DateTime.tryParse(j['completed_at'] as String? ?? ''),
        completedBy = j['completed_by'] as String?,
        completedByName = j['completed_by_name'] as String?,
        notes = j['notes'] as String?;
  final String id, status, type;
  final String? areaId, categoryId, notes, completedBy, completedByName;
  final DateTime startedAt;
  final DateTime? completedAt;
  bool get open => status == 'draft' || status == 'in_progress';
}

class InventoryCountLine {
  InventoryCountLine.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        name = j['item_name'] as String,
        location = j['location_name'] as String,
        unit = j['count_unit'] as String,
        size = j['size_label'] as String?,
        previous = j['previous_quantity']?.toString(),
        counted = j['counted_quantity']?.toString(),
        cost = j['unit_cost_snapshot']?.toString(),
        variance = j['variance_quantity']?.toString(),
        varianceValue = j['variance_value']?.toString();
  final String id, name, location, unit;
  final String? size, previous, counted, cost, variance, varianceValue;
}

class InventoryHistory {
  InventoryHistory.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        itemId = j['inventory_item_id'] as String?,
        stockId = j['stock_id'] as String?,
        name = j['item_name'] as String,
        location = j['location_name'] as String,
        unit = j['count_unit'] as String,
        action = j['action_type'] as String,
        previous = j['previous_quantity']?.toString(),
        change = j['quantity_change']?.toString(),
        quantity = j['new_quantity']?.toString(),
        cost = j['unit_cost_snapshot']?.toString(),
        reason = j['reason'] as String?,
        notes = j['notes'] as String?,
        actorId = j['performed_by'] as String?,
        actorName = j['actor_name'] as String?,
        createdAt = DateTime.parse(j['created_at'] as String);
  final String id, name, location, unit, action;
  final String? itemId,
      stockId,
      previous,
      change,
      quantity,
      cost,
      reason,
      notes,
      actorId;
  final DateTime createdAt;
  final String? actorName;
}

class InventorySnapshot {
  const InventorySnapshot({
    required this.items,
    required this.categories,
    required this.subcategories,
    required this.areas,
    required this.subAreas,
    required this.stock,
    required this.counts,
    required this.history,
    this.outstandingCountRows = 0,
  });
  final int outstandingCountRows;
  final List<InventoryItem> items;
  final List<InventoryCategory> categories, subcategories;
  final List<InventoryArea> areas, subAreas;
  final List<InventoryStock> stock;
  final List<InventoryCount> counts;

  /// All history within the last thirty days, used for recent variance metrics.
  final List<InventoryHistory> history;
  InventoryItem? item(String id) => items.where((i) => i.id == id).firstOrNull;
  String categoryName(String? id) =>
      categories.where((c) => c.id == id).firstOrNull?.name ?? 'Uncategorized';
  String subcategoryName(String? id) =>
      subcategories.where((c) => c.id == id).firstOrNull?.name ?? '';
  String group(InventoryItem i) =>
      categories.where((c) => c.id == i.categoryId).firstOrNull?.group ??
      'Uncategorized';
  String location(InventoryStock s) =>
      '${areas.where((a) => a.id == s.areaId).firstOrNull?.name ?? 'Archived area'}${s.subAreaId == null ? '' : ' / ${subAreas.where((a) => a.id == s.subAreaId).firstOrNull?.name ?? 'Archived sub-area'}'}';
  bool activeStock(InventoryStock s) =>
      item(s.itemId)?.active == true &&
      areas.any((a) => a.id == s.areaId && a.active) &&
      (s.subAreaId == null ||
          subAreas.any((a) => a.id == s.subAreaId && a.active));
  List<InventoryStock> get activePositions => stock.where(activeStock).toList();
  BigInt get value => activePositions.fold(
        BigInt.zero,
        (total, s) =>
            total + inventoryValue(s.quantity, item(s.itemId)?.unitCostUsd),
      );
  BigInt get recentVariance => history.where((h) => h.action == 'COUNT').fold(
        BigInt.zero,
        (total, h) => total + inventoryValue(h.change, h.cost),
      );
  BigInt totalFor(String id) => stock
      .where((s) => s.itemId == id)
      .fold(BigInt.zero, (n, s) => n + inventoryDecimal(s.quantity));
}

class InventoryMatch {
  const InventoryMatch(this.item, this.confidence, this.label);
  final InventoryItem? item;
  final int confidence;
  final String label;
}

InventoryMatch matchInventoryItem(String name, List<InventoryItem> items) {
  String normalized(String s) =>
      s.toLowerCase().replaceAll(RegExp('[^a-z0-9]'), '');
  final key = normalized(name);
  final exact =
      items.where((i) => i.active && normalized(i.name) == key).toList();
  if (exact.length == 1) {
    return InventoryMatch(
      exact.single,
      100,
      'Exact name match — confirm size and unit',
    );
  }
  if (exact.length > 1) {
    return const InventoryMatch(
      null,
      0,
      'Several items share this name — choose the correct size',
    );
  }
  final candidates = items
      .where(
        (i) =>
            i.active &&
            (normalized(i.name).contains(key) ||
                key.contains(normalized(i.name))),
      )
      .toList();
  if (key.length >= 4 && candidates.length == 1) {
    return InventoryMatch(
      candidates.single,
      60,
      'Possible name match — review carefully',
    );
  }
  return const InventoryMatch(null, 0, 'No confident match');
}
