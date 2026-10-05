import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/location/location_service.dart';
import '../../../core/network/supabase_providers.dart';
import '../data/time_clock_repository.dart';
import '../domain/time_entry.dart';

final timeClockRepositoryProvider = Provider<TimeClockRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseTimeClockRepository(client);
});

final locationServiceProvider =
    Provider<LocationService>((ref) => const GeolocatorLocationService());

final activeTimeEntryProvider =
    FutureProvider.autoDispose.family<TimeEntry?, String>((ref, venueId) {
  return ref
      .watch(timeClockRepositoryProvider)
      .getActiveEntry(venueId: venueId);
});

final myTimeEntriesProvider =
    FutureProvider.autoDispose.family<List<TimeEntry>, String>((ref, venueId) {
  return ref.watch(timeClockRepositoryProvider).getMyEntries(venueId: venueId);
});

final venueClockBoardProvider =
    FutureProvider.autoDispose.family<List<TimeEntry>, String>((ref, venueId) {
  return ref
      .watch(timeClockRepositoryProvider)
      .getVenueEntries(venueId: venueId);
});
