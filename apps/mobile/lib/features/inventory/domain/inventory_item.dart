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
    required this.updatedAt,
  });

  final String id;
  final String venueId;
  final String name;
  final num? quantity;
  final String? unit;
  final num? unitCostUsd;
  final DateTime updatedAt;

  factory InventoryItem.fromJson(Map<String, dynamic> json) => InventoryItem(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        name: json['name'] as String,
        quantity: json['quantity'] as num?,
        unit: json['unit'] as String?,
        unitCostUsd: json['unit_cost_usd'] as num?,
        updatedAt: DateTime.parse(json['updated_at'] as String),
      );

  @override
  bool operator ==(Object other) => other is InventoryItem && other.id == id;

  @override
  int get hashCode => id.hashCode;
}
