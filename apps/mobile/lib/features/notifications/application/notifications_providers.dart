import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/domain/venue.dart';
import '../data/notifications_repository.dart';
import '../domain/notification_event.dart';
import 'notification_tap_service.dart';
import 'push_registration_service.dart';

final notificationsRepositoryProvider =
    Provider<NotificationsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseNotificationsRepository(client);
});

final pushRegistrationServiceProvider =
    Provider<PushRegistrationService>((ref) {
  return PushRegistrationService(
    repository: ref.watch(notificationsRepositoryProvider),
  );
});

/// Stateless bridge to the tapped-notification payload — see its own doc comment. Routing the
/// payload to an actual app route lives in `app/router.dart`'s `notificationTapRoutingProvider`,
/// not here, so this file never has to import the router (which itself depends on screens that
/// import this file).
final notificationTapServiceProvider = Provider<NotificationTapService>((ref) {
  final service = NotificationTapService();
  ref.onDispose(() => unawaited(service.dispose()));
  return service;
});

/// Watching this provider anywhere (app/app.dart does, once, app-wide) activates a listener
/// that registers a push token for whichever venue is currently active, every time that
/// changes — including the first time one is selected after sign-in. Same "side effect only,
/// watch it once at the app root" pattern as offlineQueueConnectivityProvider and
/// appAttestTriggerProvider. It has no state of its own.
///
/// Fire-and-forget: registerForVenue() already never throws (see its own doc), and a failure
/// here has no user-visible consequence beyond that venue not receiving push notifications
/// until the next successful registration attempt (e.g. a later app launch).
final pushRegistrationTriggerProvider = Provider<void>((ref) {
  ref.listen<Venue?>(
    activeVenueProvider,
    (previous, next) {
      if (next == null) return;
      // ignore: unawaited_futures
      ref.read(pushRegistrationServiceProvider).registerForVenue(next.id);
    },
    fireImmediately: true,
  );
});

final notificationsFeedProvider =
    FutureProvider.autoDispose<List<NotificationEvent>>((ref) async {
  final currentVenue = ref.watch(activeVenueProvider);
  if (currentVenue == null) return [];

  final repo = ref.watch(notificationsRepositoryProvider);
  return repo.getNotifications(venueId: currentVenue.id);
});

final unreadNotificationsCountProvider = Provider.autoDispose<int>((ref) {
  final feed = ref.watch(notificationsFeedProvider).valueOrNull ?? [];
  return feed.where((e) => !e.isRead).length;
});
