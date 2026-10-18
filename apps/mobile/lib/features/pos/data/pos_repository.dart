import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/pos_check.dart';
import '../domain/pos_connection.dart';

abstract class PosRepository {
  Future<List<PosConnection>> getConnections({required String venueId});
  Future<List<Map<String, dynamic>>> getCapabilities(String connectionId);
  Future<List<Map<String, dynamic>>> getOutboundJobs(String connectionId);
  Future<String> requestConnection({
    required String venueId,
    required String provider,
  });
  Future<int> publishSchedule(String connectionId);
  Future<List<PosCheck>> getRecentChecks({
    required String venueId,
    int limit = 50,
  });
  Future<void> push86Item({
    required String venueId,
    required String itemGuid,
    required bool isAvailable,
  });
}

const _checkColumns =
    'id,organization_id,venue_id,pos_connection_id,provider,external_check_id,'
    'table_label,server_name,guest_name,guest_count,opened_at,closed_at,subtotal_cents,'
    'tax_cents,tip_cents,total_cents,status,menu_items,created_at,updated_at';

class SupabasePosRepository implements PosRepository {
  SupabasePosRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<String> requestConnection({
    required String venueId,
    required String provider,
  }) async {
    final id = await _client.rpc(
      'request_pos_connection',
      params: {'p_venue_id': venueId, 'p_provider': provider},
    );
    return id as String;
  }

  @override
  Future<List<Map<String, dynamic>>> getCapabilities(
    String connectionId,
  ) async {
    final rows = await _client
        .from('pos_connection_capabilities')
        .select(
          'capability,state,verified_at,evidence_url',
        )
        .eq('connection_id', connectionId)
        .order('capability');
    return rows;
  }

  @override
  Future<List<Map<String, dynamic>>> getOutboundJobs(
    String connectionId,
  ) async {
    final rows = await _client
        .from('pos_outbound_jobs')
        .select(
          'id,operation,status,error_code,created_at,completed_at',
        )
        .eq('connection_id', connectionId)
        .order('created_at', ascending: false)
        .limit(20);
    return rows;
  }

  @override
  Future<int> publishSchedule(String connectionId) async {
    final result = await _client.rpc(
      'publish_pos_schedule',
      params: {'p_connection_id': connectionId},
    );
    return result as int;
  }

  @override
  Future<List<PosConnection>> getConnections({required String venueId}) async {
    final response = await _client
        .from('pos_connections')
        .select(
          'id,organization_id,venue_id,provider,product,external_location_id,status,readiness,last_sync_at,created_at,updated_at',
        )
        .eq('venue_id', venueId)
        .order('provider', ascending: true);

    return (response as List<dynamic>)
        .map((row) => PosConnection.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<List<PosCheck>> getRecentChecks({
    required String venueId,
    int limit = 50,
  }) async {
    final response = await _client
        .from('pos_checks')
        // Explicit columns: clients have no privilege on raw_payload (it can carry customer data),
        // so a bare select() (select *) is refused by Postgres.
        .select(_checkColumns)
        .eq('venue_id', venueId)
        .order('opened_at', ascending: false)
        .limit(limit);

    return (response as List<dynamic>)
        .map((row) => PosCheck.fromJson(row as Map<String, dynamic>))
        .toList();
  }

  @override
  Future<void> push86Item({
    required String venueId,
    required String itemGuid,
    required bool isAvailable,
  }) async =>
      throw UnsupportedError(
        'Toast item availability has no verified delivery worker.',
      );
}
