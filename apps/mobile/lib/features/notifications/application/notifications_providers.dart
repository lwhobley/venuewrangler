import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../data/notifications_repository.dart';
import '../domain/notification_event.dart';

final notificationsRepositoryProvider = Provider<NotificationsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseNotificationsRepository(client);
});

final notificationsFeedProvider = FutureProvider.autoDispose<List<NotificationEvent>>((ref) async {
  final currentVenue = ref.watch(activeVenueProvider);
  if (currentVenue == null) return [];

  final repo = ref.watch(notificationsRepositoryProvider);
  return repo.getNotifications(venueId: currentVenue.id);
});

final unreadNotificationsCountProvider = Provider.autoDispose<int>((ref) {
  final feed = ref.watch(notificationsFeedProvider).valueOrNull ?? [];
  return feed.where((e) => !e.isRead).length;
});
