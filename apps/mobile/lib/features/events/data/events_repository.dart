import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/event.dart';

/// As with the other Phase 2/3 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002180000_events_schema.sql) — this class does not duplicate role
/// checks.
abstract interface class EventsRepository {
  Future<List<VenueEvent>> fetchEventsForVenue(String venueId);

  Future<void> createEvent({
    required String venueId,
    required String name,
    required DateTime startTime,
    required DateTime endTime,
    String? notes,
  });

  Future<void> updateStatus(String eventId, EventStatus status);

  Future<void> deleteEvent(String eventId);
}

class SupabaseEventsRepository implements EventsRepository {
  const SupabaseEventsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<VenueEvent>> fetchEventsForVenue(String venueId) async {
    final rows = await _client
        .from('events')
        .select()
        .eq('venue_id', venueId)
        .order('start_time');

    return rows.map(VenueEvent.fromJson).toList(growable: false);
  }

  @override
  Future<void> createEvent({
    required String venueId,
    required String name,
    required DateTime startTime,
    required DateTime endTime,
    String? notes,
  }) async {
    await _client.from('events').insert({
      'venue_id': venueId,
      'name': name,
      'start_time': startTime.toUtc().toIso8601String(),
      'end_time': endTime.toUtc().toIso8601String(),
      if (notes != null) 'notes': notes,
    });
  }

  @override
  Future<void> updateStatus(String eventId, EventStatus status) async {
    final row = await _client
        .from('events')
        .update({'status': status.toDb()})
        .eq('id', eventId)
        .select('id')
        .maybeSingle();
    if (row == null) {
      throw const PostgrestException(
        message: 'Event update was not applied',
        code: '42501',
      );
    }
  }

  @override
  Future<void> deleteEvent(String eventId) async {
    final row = await _client
        .from('events')
        .delete()
        .eq('id', eventId)
        .select('id')
        .maybeSingle();
    if (row == null) {
      throw const PostgrestException(
        message: 'Event deletion was not applied',
        code: '42501',
      );
    }
  }
}
