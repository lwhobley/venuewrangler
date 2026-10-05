import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/time_entry.dart';

abstract interface class TimeClockRepository {
  Future<TimeEntry?> getActiveEntry({required String venueId});

  Future<List<TimeEntry>> getMyEntries({
    required String venueId,
    int limit = 20,
  });

  Future<List<TimeEntry>> getVenueEntries({
    required String venueId,
    int limit = 50,
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
  const SupabaseTimeClockRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<TimeEntry?> getActiveEntry({required String venueId}) async {
    try {
      final user = _client.auth.currentUser;
      if (user == null) return null;

      final row = await _client
          .from('time_entries')
          .select()
          .eq('venue_id', venueId)
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
  Future<TimeEntry> clockIn({
    required String venueId,
    String? shiftId,
    required double lat,
    required double lng,
    required double accuracyM,
    bool mocked = false,
  }) async {
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
    try {
      final now = DateTime.now().toIso8601String();
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
        'start_at': DateTime.now().toIso8601String(),
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
      final now = DateTime.now().toIso8601String();
      final updatedBreaks = entry.breaks.map((b) {
        if (b.isOpen) {
          return {
            'type': b.type,
            'start_at': b.startAt.toIso8601String(),
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

  AppError _mapPostgrestException(PostgrestException e) {
    if (e.code == '23505') {
      return const UnknownError('You are already clocked in.');
    }
    if (e.code == '42501') {
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
