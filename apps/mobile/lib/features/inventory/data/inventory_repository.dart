import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/inventory_item.dart';
import '../domain/inventory_v2.dart';

/// As with the other Phase 2/3 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002110000_inventory_schema.sql) — this class does not duplicate
/// role checks. Inventory V2 RPCs perform their own server-side authorization.
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

  Future<InventorySnapshot> fetchSnapshot(
    String venueId,
    String organizationId,
  );
  Future<String> saveItem(
    String venueId,
    Map<String, dynamic> values, {
    String? id,
  });
  Future<void> saveMetadata(
    String table,
    Map<String, dynamic> values, {
    String? id,
  });
  Future<String> setStock(
    String itemId,
    String areaId, {
    String? subAreaId,
    String? par,
  });
  Future<void> applyAction(
    String stockId,
    String action,
    String quantity, {
    required String operationId,
    String? destinationId,
    String? reason,
    String? notes,
  });
  Future<String> startCount(
    String venueId, {
    required String type,
    String? areaId,
    String? categoryId,
    String? subcategoryId,
    String? notes,
  });
  Future<List<InventoryCountLine>> fetchCountLines(String countId);
  Future<void> saveCount(
    String countId,
    List<Map<String, dynamic>> values, {
    bool complete = false,
    bool cancel = false,
  });
  Future<List<InventoryHistory>> fetchItemHistory(String itemId);
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
    await _client
        .from('inventory_items')
        .update({'quantity': quantity}).eq('id', itemId);
  }

  @override
  Future<void> deleteItem(String itemId) async {
    await _client
        .from('inventory_items')
        .update({'is_active': false}).eq('id', itemId);
  }

  // Avoid the Data API's default 1000-row limit truncating stock and valuations.
  Future<List<Map<String, dynamic>>> _pages(
    Future<List<Map<String, dynamic>>> Function(int, int) query,
  ) async {
    final rows = <Map<String, dynamic>>[];
    for (var start = 0;; start += 500) {
      final page = await query(start, start + 499);
      rows.addAll(page);
      if (page.length < 500) return rows;
    }
  }

  @override
  Future<InventorySnapshot> fetchSnapshot(
    String venueId,
    String organizationId,
  ) async {
    final since = DateTime.now()
        .toUtc()
        .subtract(const Duration(days: 30))
        .toIso8601String();
    final data = await Future.wait([
      _pages(
        (a, b) => _client
            .from('inventory_items')
            .select()
            .eq('venue_id', venueId)
            .order('id')
            .range(a, b),
      ),
      _pages(
        (a, b) => _client
            .from('inventory_categories')
            .select()
            .eq('organization_id', organizationId)
            .order('id')
            .range(a, b),
      ),
      _pages(
        (a, b) => _client
            .from('inventory_subcategories')
            .select()
            .eq('organization_id', organizationId)
            .order('id')
            .range(a, b),
      ),
      _pages(
        (a, b) => _client
            .from('inventory_areas')
            .select()
            .eq('venue_id', venueId)
            .order('id')
            .range(a, b),
      ),
      _pages(
        (a, b) => _client
            .from('inventory_sub_areas')
            .select()
            .eq('venue_id', venueId)
            .order('id')
            .range(a, b),
      ),
      _pages(
        (a, b) => _client
            .from('inventory_stock')
            .select()
            .eq('venue_id', venueId)
            .order('id')
            .range(a, b),
      ),
      _client
          .from('inventory_counts')
          .select()
          .eq('venue_id', venueId)
          .order('started_at', ascending: false)
          .limit(100),
      _pages(
        (a, b) => _client
            .from('inventory_history')
            .select()
            .eq('venue_id', venueId)
            .gte('created_at', since)
            .order('id')
            .range(a, b),
      ),
    ]);
    final summary = await _client
        .rpc('inventory_dashboard', params: {'p_venue': venueId}) as Map;
    final history = await _history(data[7]);
    final countNames = await _actorNames(
      data[6].map((r) => r['completed_by'] as String?).whereType<String>(),
    );
    final items = data[0].map(InventoryItem.fromJson).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return InventorySnapshot(
      items: items,
      categories: data[1].map(InventoryCategory.fromJson).toList()
        ..sort((a, b) => a.name.compareTo(b.name)),
      subcategories: data[2].map(InventoryCategory.fromJson).toList()
        ..sort((a, b) => a.name.compareTo(b.name)),
      areas: data[3].map(InventoryArea.fromJson).toList()
        ..sort((a, b) => a.name.compareTo(b.name)),
      subAreas: data[4].map(InventoryArea.fromJson).toList()
        ..sort((a, b) => a.name.compareTo(b.name)),
      stock: data[5].map(InventoryStock.fromJson).toList(),
      counts: data[6]
          .map(
            (r) => InventoryCount.fromJson(
              {...r, 'completed_by_name': countNames[r['completed_by']]},
            ),
          )
          .toList(),
      history: history..sort((a, b) => b.createdAt.compareTo(a.createdAt)),
      outstandingCountRows: summary['uncounted'] as int? ?? 0,
    );
  }

  @override
  Future<String> saveItem(
    String venueId,
    Map<String, dynamic> values, {
    String? id,
  }) async {
    final row = id == null
        ? await _client
            .from('inventory_items')
            .insert({...values, 'venue_id': venueId})
            .select('id')
            .single()
        : await _client
            .from('inventory_items')
            .update(values)
            .eq('id', id)
            .eq('venue_id', venueId)
            .select('id')
            .single();
    return row['id'] as String;
  }

  @override
  Future<void> saveMetadata(
    String table,
    Map<String, dynamic> values, {
    String? id,
  }) async {
    if (!{
      'inventory_categories',
      'inventory_subcategories',
      'inventory_areas',
      'inventory_sub_areas',
    }.contains(table)) {
      throw ArgumentError('Invalid inventory metadata table');
    }
    if (id == null) {
      await _client.from(table).insert(values).select('id').single();
    } else {
      await _client
          .from(table)
          .update(values)
          .eq('id', id)
          .select('id')
          .single();
    }
  }

  @override
  Future<String> setStock(
    String itemId,
    String areaId, {
    String? subAreaId,
    String? par,
  }) async =>
      await _client.rpc(
        'inventory_set_stock',
        params: {
          'p_item': itemId,
          'p_area': areaId,
          'p_sub_area': subAreaId,
          'p_par': par,
        },
      ) as String;

  @override
  Future<void> applyAction(
    String stockId,
    String action,
    String quantity, {
    required String operationId,
    String? destinationId,
    String? reason,
    String? notes,
  }) async {
    await _client.rpc(
      'inventory_apply_action',
      params: {
        'p_stock': stockId,
        'p_action': action,
        'p_quantity': quantity,
        'p_operation_id': operationId,
        'p_destination': destinationId,
        'p_reason': reason,
        'p_notes': notes,
      },
    );
  }

  @override
  Future<String> startCount(
    String venueId, {
    required String type,
    String? areaId,
    String? categoryId,
    String? subcategoryId,
    String? notes,
  }) async =>
      await _client.rpc(
        'inventory_start_count',
        params: {
          'p_venue': venueId,
          'p_type': type,
          'p_area': areaId,
          'p_category': categoryId,
          'p_subcategory': subcategoryId,
          'p_notes': notes,
        },
      ) as String;

  @override
  Future<List<InventoryCountLine>> fetchCountLines(String countId) async =>
      (await _pages(
        (a, b) => _client
            .from('inventory_count_items')
            .select()
            .eq('count_id', countId)
            .order('location_name')
            .order('item_name')
            .order('id')
            .range(a, b),
      ))
          .map(InventoryCountLine.fromJson)
          .toList();

  @override
  Future<void> saveCount(
    String countId,
    List<Map<String, dynamic>> values, {
    bool complete = false,
    bool cancel = false,
  }) async {
    await _client.rpc(
      'inventory_save_count',
      params: {
        'p_count': countId,
        'p_values': values,
        'p_complete': complete,
        'p_cancel': cancel,
      },
    );
  }

  @override
  Future<List<InventoryHistory>> fetchItemHistory(String itemId) async =>
      _history(
        await _client
            .from('inventory_history')
            .select()
            .eq('inventory_item_id', itemId)
            .order('created_at', ascending: false)
            .limit(100),
      );

  Future<List<InventoryHistory>> _history(
    List<Map<String, dynamic>> rows,
  ) async {
    final names = await _actorNames(
      rows.map((r) => r['performed_by'] as String?).whereType<String>(),
    );
    return rows
        .map(
          (r) => InventoryHistory.fromJson(
            {...r, 'actor_name': names[r['performed_by']]},
          ),
        )
        .toList();
  }

  Future<Map<String, String>> _actorNames(Iterable<String> actorIds) async {
    final ids = actorIds.toSet().toList();
    final names = <String, String>{};
    for (var start = 0; start < ids.length; start += 400) {
      final group = ids.sublist(start, (start + 400).clamp(0, ids.length));
      final profiles = await _client
          .from('profiles')
          .select('id,display_name')
          .inFilter('id', group);
      for (final profile in profiles) {
        if ((profile['display_name'] as String?)?.trim().isNotEmpty == true) {
          names[profile['id'] as String] = profile['display_name'] as String;
        }
      }
    }
    return names;
  }
}
