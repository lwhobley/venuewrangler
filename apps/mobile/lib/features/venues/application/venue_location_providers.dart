import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/venue_location_repository.dart';
import 'venues_providers.dart';

final venueLocationRepositoryProvider = Provider<VenueLocationRepository>(
  (ref) => VenueLocationRepository(ref.watch(supabaseClientProvider)),
);

/// True when the signed-in manager's active venue has no clock-in geofence, so every punch
/// there fails with `venue_geofence_required` until one is set. Always false for anyone who
/// cannot set the location (the server refuses them anyway), and the lookup is skipped for
/// them entirely.
final activeVenueMissingGeofenceProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final venue = ref.watch(activeVenueProvider);
  if (venue == null) return false;
  if (!await ref.watch(canManageActiveVenueProvider.future)) return false;
  final configured =
      await ref.watch(venueLocationRepositoryProvider).hasGeofence(venue.id);
  return !configured;
});
