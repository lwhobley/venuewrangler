import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/notification_event.dart';

abstract interface class NotificationsRepository {
  Future<String> registerPushToken({
    required String venueId,
    required String token,
    required String platform,
  });

  Future<List<NotificationEvent>> getNotifications({
    required String venueId,
    int limit = 50,
  });

  Future<void> markAsRead({required String notificationId});

  Future<void> markAllAsRead({required String venueId});
}

class SupabaseNotificationsRepository implements NotificationsRepository {
  const SupabaseNotificationsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<String> registerPushToken({
    required String venueId,
    required String token,
    required String platform,
  }) async {
    try {
      final res = await _client.rpc(
        'register_push_token',
        params: {
          'p_venue_id': venueId,
          'p_token': token,
          'p_platform': platform,
        },
      );
      return res as String;
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        throw const PermissionDeniedError('Unable to register push token: permission denied.');
      }
      throw UnknownError('Push token registration failed: ${e.message}');
    } catch (e) {
      throw UnknownError('Unexpected error registering device token: $e');
    }
  }

  @override
  Future<List<NotificationEvent>> getNotifications({
    required String venueId,
    int limit = 50,
  }) async {
    try {
      final rows = await _client
          .from('notification_events')
          .select()
          .eq('venue_id', venueId)
          .order('created_at', ascending: false)
          .limit(limit);

      return (rows as List<dynamic>)
          .map((r) => NotificationEvent.fromMap(r as Map<String, dynamic>))
          .toList();
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        throw const PermissionDeniedError();
      }
      throw UnknownError('Failed to load notifications: ${e.message}');
    } catch (e) {
      throw UnknownError('Unexpected error loading notifications: $e');
    }
  }

  @override
  Future<void> markAsRead({required String notificationId}) async {
    try {
      await _client
          .from('notification_events')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('id', notificationId);
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        throw const PermissionDeniedError();
      }
      throw UnknownError('Failed to mark notification as read: ${e.message}');
    } catch (e) {
      throw UnknownError('Unexpected error marking notification read: $e');
    }
  }

  @override
  Future<void> markAllAsRead({required String venueId}) async {
    try {
      await _client
          .from('notification_events')
          .update({'read_at': DateTime.now().toUtc().toIso8601String()})
          .eq('venue_id', venueId)
          .isFilter('read_at', null);
    } on PostgrestException catch (e) {
      if (e.code == '42501') {
        throw const PermissionDeniedError();
      }
      throw UnknownError('Failed to mark all notifications read: ${e.message}');
    } catch (e) {
      throw UnknownError('Unexpected error marking all notifications read: $e');
    }
  }
}
