import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/incident.dart';

/// As with the other Phase 2 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002030000_incidents_schema.sql) — this class does not duplicate
/// role checks.
abstract interface class IncidentsRepository {
  Future<List<Incident>> fetchIncidentsForVenue(String venueId);

  /// Idempotent for the same [incidentId], same reasoning as
  /// ChecklistsRepository.submitCompletion: a plain insert that hits a duplicate key (an
  /// earlier retry already succeeded) is treated as success rather than an error, since
  /// reporting an incident is an insert with nothing sensible to "update into" on retry.
  Future<void> reportIncident({
    required String incidentId,
    required String venueId,
    required String title,
    String? description,
    required IncidentSeverity severity,
  });

  Future<void> updateStatus(String incidentId, IncidentStatus status);
}

class SupabaseIncidentsRepository implements IncidentsRepository {
  const SupabaseIncidentsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Incident>> fetchIncidentsForVenue(String venueId) async {
    final rows = await _client
        .from('incidents')
        .select()
        .eq('venue_id', venueId)
        .order('created_at', ascending: false);

    return rows.map(Incident.fromJson).toList(growable: false);
  }

  @override
  Future<void> reportIncident({
    required String incidentId,
    required String venueId,
    required String title,
    String? description,
    required IncidentSeverity severity,
  }) async {
    try {
      await _client.from('incidents').insert({
        'id': incidentId,
        'venue_id': venueId,
        'title': title,
        if (description != null) 'description': description,
        'severity': severity.toDb(),
      });
    } on PostgrestException catch (error) {
      if (error.code == '23505') return; // already submitted by an earlier retry; done.
      rethrow;
    }
  }

  @override
  Future<void> updateStatus(String incidentId, IncidentStatus status) async {
    await _client.from('incidents').update({'status': status.toDb()}).eq('id', incidentId);
  }
}
