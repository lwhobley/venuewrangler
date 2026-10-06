import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/editor_table.dart';
import '../domain/floor_plan.dart';
import '../domain/floor_table.dart';

abstract class FloorRepository {
  Future<List<FloorPlan>> getFloorPlans({required String venueId});
  Future<List<FloorTable>> getFloorTables({required String floorPlanId});
  Future<FloorPlan> createFloorPlan({
    required String venueId,
    required String name,
  });
  Future<void> saveLayout({
    required String venueId,
    required String floorPlanId,
    required List<EditorTable> created,
    required List<EditorTable> updated,
    required List<String> removedIds,
  });
  Stream<List<FloorTable>> streamFloorTables({required String venueId});
  Future<void> updateTableStatus({
    required String venueId,
    required String tableId,
    required String status,
  });
  Future<String> mergeTables({
    required String venueId,
    required List<String> tableIds,
    int? partySize,
  });
  Future<void> splitTables({
    required String venueId,
    required String mergeGroupId,
  });
  Future<void> assignTables({
    required String venueId,
    required List<String> tableIds,
    required String reservationId,
    String holdType = 'seated',
  });
}

class SupabaseFloorRepository implements FloorRepository {
  SupabaseFloorRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<FloorPlan>> getFloorPlans({required String venueId}) async {
    final response = await _client
        .from('floor_plans')
        .select()
        .eq('venue_id', venueId)
        .order('name', ascending: true);

    return (response as List<dynamic>)
        .map((row) => FloorPlan.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<FloorTable>> getFloorTables({required String floorPlanId}) async {
    final response = await _client
        .from('floor_tables')
        .select()
        .eq('floor_plan_id', floorPlanId)
        .order('label', ascending: true);

    return (response as List<dynamic>)
        .map((row) => FloorTable.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<FloorPlan> createFloorPlan({
    required String venueId,
    required String name,
  }) async {
    final row = await _client
        .from('floor_plans')
        .insert({'venue_id': venueId, 'name': name})
        .select()
        .single();
    return FloorPlan.fromJson(row);
  }

  @override
  Future<void> saveLayout({
    required String venueId,
    required String floorPlanId,
    required List<EditorTable> created,
    required List<EditorTable> updated,
    required List<String> removedIds,
  }) async {
    if (removedIds.isNotEmpty) {
      await _client
          .from('floor_tables')
          .delete()
          .eq('venue_id', venueId)
          .inFilter('id', removedIds);
    }
    for (final t in updated) {
      await _client
          .from('floor_tables')
          .update(t.toLayoutColumns())
          .eq('id', t.id)
          .eq('venue_id', venueId);
    }
    if (created.isNotEmpty) {
      await _client.from('floor_tables').insert([
        for (final t in created)
          {
            'venue_id': venueId,
            'floor_plan_id': floorPlanId,
            ...t.toLayoutColumns(),
          },
      ]);
    }
  }

  @override
  Stream<List<FloorTable>> streamFloorTables({required String venueId}) {
    return _client
        .from('floor_tables')
        .stream(primaryKey: ['id'])
        .eq('venue_id', venueId)
        .order('label', ascending: true)
        .map((rows) => rows.map(FloorTable.fromJson).toList());
  }

  @override
  Future<void> updateTableStatus({
    required String venueId,
    required String tableId,
    required String status,
  }) async {
    await _client.rpc(
      'update_floor_table_status',
      params: {
        'p_venue_id': venueId,
        'p_table_id': tableId,
        'p_status': status,
      },
    );
  }

  @override
  Future<String> mergeTables({
    required String venueId,
    required List<String> tableIds,
    int? partySize,
  }) async {
    final result = await _client.rpc(
      'merge_floor_tables',
      params: {
        'p_venue_id': venueId,
        'p_table_ids': tableIds,
        if (partySize != null) 'p_party_size': partySize,
      },
    );
    return result as String;
  }

  @override
  Future<void> splitTables({
    required String venueId,
    required String mergeGroupId,
  }) async {
    await _client.rpc(
      'split_floor_tables',
      params: {
        'p_venue_id': venueId,
        'p_merge_group_id': mergeGroupId,
      },
    );
  }

  @override
  Future<void> assignTables({
    required String venueId,
    required List<String> tableIds,
    required String reservationId,
    String holdType = 'seated',
  }) async {
    await _client.rpc(
      'assign_tables_to_reservation',
      params: {
        'p_venue_id': venueId,
        'p_table_ids': tableIds,
        'p_reservation_id': reservationId,
        'p_hold_type': holdType,
      },
    );
  }
}
