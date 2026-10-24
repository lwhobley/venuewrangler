import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/time_entry.dart';
import 'attested_punch_client.dart';

abstract interface class TimeClockRepository {
  /// Returns the user's open entry *at [venueId]*, or null. The database allows only one open
  /// entry per user (time_entries_one_open_per_user_idx), so an entry open at another venue is
  /// not reported here; use [getOpenEntryElsewhere] to detect it. Clock-out operates on the
  /// entry returned here, i.e. always on the entry for the venue it was started at.
  Future<TimeEntry?> getActiveEntry({required String venueId});

  /// Returns the user's open entry when it belongs to a venue other than [venueId], else null.
  /// The UI must show it as "clocked in at another venue" and must not clock in, out, or take
  /// breaks on it from this venue.
  Future<TimeEntry?> getOpenEntryElsewhere({required String venueId});

  Future<List<TimeEntry>> getMyEntries({
    required String venueId,
    int limit = 20,
  });

  /// Every person's entries at [venueId] that clocked in within [from, to), open or finished
  /// (managers' RLS; the shift handover reviews them for exceptions).
  Future<List<TimeEntry>> getVenueEntriesInRange({
    required String venueId,
    required DateTime from,
    required DateTime to,
    int limit = 200,
  });

  Future<TimeEntry> clockIn({
    required String venueId,
    String? shiftId,
    required double lat,
    required double lng,
    required double accuracyM,
    bool mocked = false,
  });

  Future<TimeEntry> clockOut({
    required String entryId,
    required double lat,
    required double lng,
    required double accuracyM,
    bool mocked = false,
  });

  Future<TimeEntry> startBreak({
    required TimeEntry entry,
    required String type,
  });

  Future<TimeEntry> endBreak({
    required TimeEntry entry,
  });
}

class SupabaseTimeClockRepository implements TimeClockRepository {
  /// With an [attestedPunches] client, punches go through the verified path first and fall back
  /// to the direct database insert only when the server function is unavailable (an older
  /// backend, or it is down). A policy refusal from the server is never retried directly.
  const SupabaseTimeClockRepository(
    this._client, {
    AttestedPunchClient? attestedPunches,
  }) : _attested = attestedPunches;

  final SupabaseClient _client;
  final AttestedPunchClient? _attested;

  @override
  Future<TimeEntry?> getActiveEntry({required String venueId}) async {
    final open = await _openEntry();
    return open != null && open.venueId == venueId ? open : null;
  }

  @override
  Future<TimeEntry?> getOpenEntryElsewhere({required String venueId}) async {
    final open = await _openEntry();
    return open != null && open.venueId != venueId ? open : null;
  }

  /// The user's single open entry across all venues, if any.
  Future<TimeEntry?> _openEntry() async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final row = await _client
          .from('time_entries')
          .select()
          .eq('user_id', user.id)
          .eq('is_open', true)
          .maybeSingle();

      return row != null ? TimeEntry.fromJson(row) : null;
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<List<TimeEntry>> getMyEntries({
    required String venueId,
    int limit = 20,
  }) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return const [];

      final rows = await _client
          .from('time_entries')
          .select()
          .eq('venue_id', venueId)
          .eq('user_id', user.id)
          .order('clock_in_at', ascending: false)
          .limit(limit);

      return (rows as List<dynamic>)
          .map((row) => TimeEntry.fromJson(row as Map<String, dynamic>))
          .toList(growable: false);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<List<TimeEntry>> getVenueEntries({
    required String venueId,
    int limit = 50,
  }) async {
    try {
      final rows = await _client
          .from('time_entries')
          .select()
          .eq('venue_id', venueId)
          .eq('is_open', true)
          .order('clock_in_at', ascending: false)
          .limit(limit);

      return (rows as List<dynamic>)
          .map((row) => TimeEntry.fromJson(row as Map<String, dynamic>))
          .toList(growable: false);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<List<TimeEntry>> getVenueEntriesInRange({
    required String venueId,
    required DateTime from,
    required DateTime to,
    int limit = 200,
  }) async {
    try {
      final rows = await _client
          .from('time_entries')
          .select()
          .eq('venue_id', venueId)
          .gte('clock_in_at', from.toUtc().toIso8601String())
          .lt('clock_in_at', to.toUtc().toIso8601String())
          .order('clock_in_at', ascending: true)
          .limit(limit);

      return (rows as List<dynamic>)
          .map((row) => TimeEntry.fromJson(row as Map<String, dynamic>))
          .toList(growable: false);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<TimeEntry> clockIn({
    required String venueId,
    String? shiftId,
    required double lat,
    required double lng,
    required double accuracyM,
    bool mocked = false,
  }) async {
    final attested = _attested;
    if (attested != null && shiftId == null) {
      try {
        return await attested.punch(
          kind: 'in',
          venueId: venueId,
          lat: lat,
          lng: lng,
          accuracyM: accuracyM,
          mocked: mocked,
        );
      } on AttestedPunchUnavailable {
        // fall through to the direct path
      }
    }
    try {
      final row = await _client
          .from('time_entries')
          .insert({
            'venue_id': venueId,
            if (shiftId != null) 'shift_id': shiftId,
            'clock_in_lat': lat,
            'clock_in_lng': lng,
            'clock_in_accuracy_m': accuracyM,
            'clock_in_mocked': mocked,
            'is_open': true,
          })
          .select()
          .single();

      return TimeEntry.fromJson(row);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<TimeEntry> clockOut({
    required String entryId,
    required double lat,
    required double lng,
    required double accuracyM,
    bool mocked = false,
  }) async {
    final attested = _attested;
    if (attested != null) {
      try {
        final venueId = await _venueOfEntry(entryId);
        if (venueId != null) {
          return await attested.punch(
            kind: 'out',
            venueId: venueId,
            lat: lat,
            lng: lng,
            accuracyM: accuracyM,
            mocked: mocked,
          );
        }
      } on AttestedPunchUnavailable {
        // fall through to the direct path
      }
    }
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final row = await _client
          .from('time_entries')
          .update({
            'clock_out_at': now,
            'clock_out_lat': lat,
            'clock_out_lng': lng,
            'clock_out_accuracy_m': accuracyM,
            'clock_out_mocked': mocked,
            'is_open': false,
          })
          .eq('id', entryId)
          .select()
          .single();

      return TimeEntry.fromJson(row);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<TimeEntry> startBreak({
    required TimeEntry entry,
    required String type,
  }) async {
    try {
      final updatedBreaks = List<Map<String, dynamic>>.from(
        entry.breaks.map((b) => b.toJson()),
      );
      updatedBreaks.add({
        'type': type,
        'start_at': DateTime.now().toUtc().toIso8601String(),
        'end_at': null,
      });

      final row = await _client
          .from('time_entries')
          .update({'breaks': updatedBreaks})
          .eq('id', entry.id)
          .select()
          .single();

      return TimeEntry.fromJson(row);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<TimeEntry> endBreak({
    required TimeEntry entry,
  }) async {
    try {
      final now = DateTime.now().toUtc().toIso8601String();
      final updatedBreaks = entry.breaks.map((b) {
        if (b.isOpen) {
          return {
            'type': b.type,
            'start_at': b.startAt.toUtc().toIso8601String(),
            'end_at': now,
          };
        }
        return b.toJson();
      }).toList(growable: false);

      final row = await _client
          .from('time_entries')
          .update({'breaks': updatedBreaks})
          .eq('id', entry.id)
          .select()
          .single();

      return TimeEntry.fromJson(row);
    } on PostgrestException catch (e) {
      throw _mapPostgrestException(e);
    } catch (_) {
      throw const NetworkError();
    }
  }

  Future<String?> _venueOfEntry(String entryId) async {
    try {
      final row = await _client
          .from('time_entries')
          .select('venue_id')
          .eq('id', entryId)
          .maybeSingle();
      return row?['venue_id'] as String?;
    } catch (_) {
      return null;
    }
  }

  AppError _mapPostgrestException(PostgrestException e) {
    if (e.code == '23505') {
      return const UnknownError('You are already clocked in.');
    }
    if (e.code == '42501') {
      if (e.message.contains('venue_location_required')) {
        return const PermissionDeniedError(venueLocationRequiredMessage);
      }
      if (e.message.contains('geofence')) {
        return const PermissionDeniedError(
          'You are outside the venue geofence. Move closer to the venue to clock in/out.',
        );
      }
      if (e.message.contains('satellite-grade')) {
        return const PermissionDeniedError(
          'This location reading was flagged as an identical replay of an earlier fix. Please re-acquire GPS and try again.',
        );
      }
      return PermissionDeniedError(e.message);
    }
    return UnknownError(e.message);
  }
}
