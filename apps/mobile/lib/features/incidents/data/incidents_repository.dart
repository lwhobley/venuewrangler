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

  /// Short-lived signed URLs for the photos attached to [incidentId], signed in one batch.
  /// Throws when the attachments cannot be listed or none of them can be signed, so the screen
  /// can say so instead of showing "no evidence"; a path that is individually missing is skipped.
  Future<List<String>> fetchEvidenceUrls(String incidentId);
}

/// How long an evidence URL stays valid after it is signed.
const int kEvidenceUrlTtlSeconds = 600;

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
      if (error.code == '23505') {
        return; // already submitted by an earlier retry; done.
      }
      rethrow;
    }
  }

  @override
  Future<void> updateStatus(String incidentId, IncidentStatus status) async {
    final row = await _client
        .from('incidents')
        .update({'status': status.toDb()})
        .eq('id', incidentId)
        .select('id')
        .maybeSingle();
    if (row == null) {
      throw const PostgrestException(
        message: 'Incident update was not applied',
        code: '42501',
      );
    }
  }

  @override
  Future<List<String>> fetchEvidenceUrls(String incidentId) async {
    final rows = await _client
        .from('incident_attachments')
        .select('storage_path')
        .eq('incident_id', incidentId);
    final paths = [
      for (final row in rows)
        if ((row['storage_path'] as String?)?.isNotEmpty ?? false)
          row['storage_path'] as String,
    ];
    if (paths.isEmpty) return const [];

    final results = await _client.storage
        .from('incident-evidence')
        .createSignedUrlsResult(paths, kEvidenceUrlTtlSeconds);
    final urls = [
      for (final result in results)
        if (result is SignedUrlSuccess) result.signedUrl,
    ];
    if (urls.isEmpty) {
      throw StateError('None of the incident evidence could be signed.');
    }
    return urls;
  }
}
