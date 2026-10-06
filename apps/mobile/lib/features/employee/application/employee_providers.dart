import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../guests_reservations/application/guests_reservations_providers.dart';
import '../../guests_reservations/domain/reservation.dart';
import '../../schedules/application/schedules_providers.dart';
import '../../shift_mode/domain/shift_mode.dart';
import '../../venues/application/venues_providers.dart';
import '../domain/employee_day.dart';

/// All of today's reservations for the active venue (the business day, 6am–6am).
final todaysReservationsProvider =
    FutureProvider.autoDispose<List<Reservation>>((ref) async {
  final venue = ref.watch(activeVenueProvider);
  if (venue == null) return const [];
  final w = businessDayWindow(DateTime.now());
  return ref.watch(guestsReservationsRepositoryProvider).getReservations(
        venueId: venue.id,
        from: w.start,
        to: w.end,
        limit: 500,
      );
});

/// The section the signed-in person is working right now (from their current shift).
final mySectionProvider = Provider.autoDispose<String?>((ref) {
  final venue = ref.watch(activeVenueProvider);
  if (venue == null) return null;
  final shifts = ref.watch(shiftsForVenueProvider(venue.id)).valueOrNull;
  if (shifts == null) return null;
  final current =
      myShifts(shifts, ref.watch(currentUserIdProvider), DateTime.now())
          .current;
  final section = current?.section?.trim();
  return section == null || section.isEmpty ? null : section;
});
