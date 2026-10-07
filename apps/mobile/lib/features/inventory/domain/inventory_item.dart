/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
class InventoryItem {
  const InventoryItem({
    required this.id,
    required this.venueId,
    required this.name,
    this.quantity,
    this.unit,
    this.unitCostUsd,
    this.categoryId,
    this.subcategoryId,
    this.sizeAmount,
    this.sizeUnit,
    this.countUnit = 'Each',
    this.customCountUnit,
    this.supplier,
    this.notes,
    this.active = true,
    required this.updatedAt,
  });

  final String id;
  final String venueId;
  final String name;
  final num? quantity;
  final String? unit;
  final num? unitCostUsd;
  final String? categoryId,
      subcategoryId,
      sizeAmount,
      sizeUnit,
      customCountUnit,
      supplier,
      notes;
  final String countUnit;
  final bool active;
  String get displayUnit =>
      countUnit == 'Custom' ? customCountUnit ?? unit ?? 'Custom' : countUnit;
  String get sizeLabel =>
      sizeAmount == null ? displayUnit : '$sizeAmount $sizeUnit • $displayUnit';
  final DateTime updatedAt;

  factory InventoryItem.fromJson(Map<String, dynamic> json) => InventoryItem(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        name: json['name'] as String,
        quantity: json['quantity'] as num?,
        unit: json['unit'] as String?,
        unitCostUsd: json['unit_cost_usd'] as num?,
        categoryId: json['category_id'] as String?,
        subcategoryId: json['subcategory_id'] as String?,
        sizeAmount: json['size_amount']?.toString(),
        sizeUnit: json['size_unit'] as String?,
        countUnit: json['count_unit'] as String? ?? 'Each',
        customCountUnit: json['custom_count_unit'] as String?,
        supplier: json['supplier'] as String?,
        notes: json['notes'] as String?,
        active: json['is_active'] as bool? ?? true,
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  @override
  bool operator ==(Object other) => other is InventoryItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
