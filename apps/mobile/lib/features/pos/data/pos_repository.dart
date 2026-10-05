import 'package:supabase_flutter/supabase_flutter.dart';
import '../domain/pos_check.dart';
import '../domain/pos_connection.dart';

abstract class PosRepository {
  Future<List<PosConnection>> getConnections({required String venueId});
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

class SupabasePosRepository implements PosRepository {
  SupabasePosRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<PosConnection>> getConnections({required String venueId}) async {
    final response = await _client
        .from('pos_connections')
        .select()
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
        .select()
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
  }) async {
    await _client.functions.invoke(
      'toast-pos/outbound-command',
      body: {
        'venue_id': venueId,
        'command_type': 'update_item_availability_86',
        'payload': {
          'itemGuid': itemGuid,
          'isAvailable': isAvailable,
        },
      },
    );
  }
}
