import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/inventory_item.dart';

/// As with the other Phase 2/3 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002110000_inventory_schema.sql) — this class does not duplicate
/// role checks.
abstract interface class InventoryRepository {
  Future<List<InventoryItem>> fetchItemsForVenue(String venueId);

  Future<void> createItem({
    required String venueId,
    required String name,
    num? quantity,
    String? unit,
    num? unitCostUsd,
  });

  Future<void> updateQuantity(String itemId, num quantity);

  Future<void> deleteItem(String itemId);
}

class SupabaseInventoryRepository implements InventoryRepository {
  const SupabaseInventoryRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<InventoryItem>> fetchItemsForVenue(String venueId) async {
    final rows = await _client
        .from('inventory_items')
        .select()
        .eq('venue_id', venueId)
        .order('name');

    return rows.map(InventoryItem.fromJson).toList(growable: false);
  }

  @override
  Future<void> createItem({
    required String venueId,
    required String name,
    num? quantity,
    String? unit,
    num? unitCostUsd,
  }) async {
    await _client.from('inventory_items').insert({
      'venue_id': venueId,
      'name': name,
      if (quantity != null) 'quantity': quantity,
      if (unit != null) 'unit': unit,
      if (unitCostUsd != null) 'unit_cost_usd': unitCostUsd,
    });
  }

  @override
  Future<void> updateQuantity(String itemId, num quantity) async {
    await _client.from('inventory_items').update({'quantity': quantity}).eq('id', itemId);
  }

  @override
  Future<void> deleteItem(String itemId) async {
    await _client.from('inventory_items').delete().eq('id', itemId);
  }
}
