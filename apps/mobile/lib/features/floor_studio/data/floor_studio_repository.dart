import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/floor_studio.dart';

abstract class FloorStudioRepository {
  Future<List<FloorStudioLayout>> getLayouts({required String venueId});
  Future<void> saveLayout(FloorStudioLayout layout);

  /// Headcount on the reservation linked to a banquet order, or null if none.
  Future<int?> reservationPartySizeForBeo({required String beoId});
}

class SupabaseFloorStudioRepository implements FloorStudioRepository {
  SupabaseFloorStudioRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<FloorStudioLayout>> getLayouts({required String venueId}) async {
    final rows = await _client
        .from('floor_plan_studio_layouts')
        .select()
        .eq('venue_id', venueId);
    return rows
        .cast<Map<String, dynamic>>()
        .map(FloorStudioLayout.fromJson)
        .toList();
  }

  @override
  Future<void> saveLayout(FloorStudioLayout layout) async {
    await _client
        .from('floor_plan_studio_layouts')
        .upsert(layout.toUpsertJson(), onConflict: 'floor_plan_id');
  }

  @override
  Future<int?> reservationPartySizeForBeo({required String beoId}) async {
    final row = await _client
        .from('reservations')
        .select('party_size')
        .eq('beo_id', beoId)
        .maybeSingle();
    return (row?['party_size'] as num?)?.toInt();
  }
}
