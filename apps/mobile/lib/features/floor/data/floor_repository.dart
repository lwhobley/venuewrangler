import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/floor_plan.dart';
import '../domain/floor_table.dart';

abstract class FloorRepository {
  Future<List<FloorPlan>> getFloorPlans({required String venueId});
  Future<List<FloorTable>> getFloorTables({required String floorPlanId});
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
