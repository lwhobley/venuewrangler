import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../data/guests_reservations_repository.dart';
import '../domain/guest.dart';
import '../domain/reservation.dart';

final guestsReservationsRepositoryProvider = Provider<GuestsReservationsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseGuestsReservationsRepository(client);
});

final reservationsListProvider = FutureProvider.autoDispose<List<Reservation>>((ref) async {
  final activeVenue = ref.watch(activeVenueProvider);
  if (activeVenue == null) return [];

  final repo = ref.watch(guestsReservationsRepositoryProvider);
  return repo.getReservations(venueId: activeVenue.id);
});

final guestsListProvider = FutureProvider.autoDispose<List<Guest>>((ref) async {
  final activeVenue = ref.watch(activeVenueProvider);
  if (activeVenue == null) return [];

  final repo = ref.watch(guestsReservationsRepositoryProvider);
  return repo.getGuests(venueId: activeVenue.id);
});
