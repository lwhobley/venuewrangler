import 'venue_timezone.dart';

/// The single place schedules, events, reservations and the employee day turn instants into the
/// venue's wall clock and back, so no screen falls back to the device's timezone.
///
/// Two kinds of `DateTime` meet here and must not be mixed up:
///  * an *instant* is what the server stores (timestamptz); it is only ever compared, sent to
///    the server, or passed to [wall];
///  * a *wall time* is the venue's clock reading, carried in a UTC-flagged `DateTime` whose
///    fields are the venue's year/month/day/hour/minute. Arithmetic on it is free of any
///    device daylight-saving jump, and it is only displayed, picked, or passed to [instant].
class VenueClock {
  const VenueClock(this.timezoneId);

  final String timezoneId;

  /// False for a zone the app's table cannot convert. Callers must warn and refuse to save
  /// times (see [UnsupportedTimezoneBanner] and [ensureSupported]); the conversions below
  /// would otherwise silently behave as UTC.
  bool get isSupported => VenueTimezone.isSupported(timezoneId);

  /// The venue's wall time at [instant].
  DateTime wall(DateTime instant) =>
      VenueTimezone.toVenueTime(instant, timezoneId);

  /// The instant at which the venue's clock reads [wall].
  DateTime instant(DateTime wall) => VenueTimezone.toUtc(wall, timezoneId);

  /// The venue's wall time right now.
  DateTime get now => VenueTimezone.venueNow(timezoneId);

  /// The business date (midnight, wall time) an instant falls in; hours before [startHour]
  /// belong to the previous day.
  DateTime businessDate([DateTime? at, int startHour = 6]) =>
      VenueTimezone.businessDateFor(
        at ?? DateTime.now(),
        timezoneId,
        startHour: startHour,
      );

  /// The instants bounding the business day that starts at [startHour] on wall date [date].
  ({DateTime startUtc, DateTime endUtc}) businessDayRange(
    DateTime date, {
    int startHour = 6,
  }) =>
      VenueTimezone.businessDayRange(
        date,
        timezoneId,
        startHour: startHour,
      );

  String formatTime(DateTime instant) =>
      VenueTimezone.formatTime(instant, timezoneId);

  String formatDate(DateTime instant) =>
      VenueTimezone.formatShortDate(instant, timezoneId);

  /// "Oct 10, 2026 7:00 PM" for an instant.
  String formatDateTime(DateTime instant) =>
      '${formatDate(instant)} ${formatTime(instant)}';

  /// "Oct 10, 2026 7:00 PM" for a wall time.
  static String formatWallDateTime(DateTime wall) =>
      '${VenueTimezone.formatWallDate(wall)} ${VenueTimezone.formatWallTime(wall)}';

  /// Compact timeline label ("6a", "7:30p") for an instant.
  String clockLabel(DateTime instant) => wallClockLabel(wall(instant));
}

/// Compact label for a venue *wall time*: "6a", "12p", "7:30p".
String wallClockLabel(DateTime wall) {
  final h = wall.hour % 12 == 0 ? 12 : wall.hour % 12;
  final suffix = wall.hour < 12 ? 'a' : 'p';
  return wall.minute == 0
      ? '$h$suffix'
      : '$h:${wall.minute.toString().padLeft(2, '0')}$suffix';
}
