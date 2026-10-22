import '../../venues/domain/venue_timezone.dart';
import 'reservation.dart';

/// One night of the reservation book: its business date (venue wall-clock midnight, so a 1:30 AM
/// booking belongs to the night before) and its bookings, earliest first.
typedef ReservationNight = ({DateTime night, List<Reservation> reservations});

/// Groups [reservations] into nights on the venue's clock ([timezoneId]) and orders them for a
/// host: tonight and the nights ahead first, soonest first, then past nights, most recent first.
/// Within every night the earliest arrival comes first (ties broken by id, so the order is
/// stable across refreshes). [today] is the current business date (see
/// [VenueTimezone.businessDateFor]).
List<ReservationNight> reservationBook(
  Iterable<Reservation> reservations,
  String timezoneId, {
  required DateTime today,
}) {
  final byNight = <DateTime, List<Reservation>>{};
  for (final r in reservations) {
    final night = VenueTimezone.businessDateFor(r.reservationTime, timezoneId);
    byNight.putIfAbsent(night, () => []).add(r);
  }
  for (final list in byNight.values) {
    list.sort((a, b) {
      final byTime = a.reservationTime.compareTo(b.reservationTime);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
  }
  final upcoming = byNight.keys.where((d) => !d.isBefore(today)).toList()
    ..sort();
  final past = byNight.keys.where((d) => d.isBefore(today)).toList()
    ..sort((a, b) => b.compareTo(a));
  return [
    for (final night in [...upcoming, ...past])
      (night: night, reservations: byNight[night]!),
  ];
}

/// "Fri, Dec 11" for a business date from [reservationBook].
String formatNight(DateTime night) =>
    // A business date is already a wall-clock midnight; format it without another shift.
    VenueTimezone.formatDayAndDate(night, 'UTC');
