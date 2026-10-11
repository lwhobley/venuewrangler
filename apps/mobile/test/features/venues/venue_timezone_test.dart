import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_timezone.dart';

void main() {
  group('VenueTimezone', () {
    test('standard offset and daylight saving for America/New_York', () {
      // July is Daylight Saving Time (EDT = UTC-4)
      final summerUtc = DateTime.utc(2026, 7, 15, 12, 0);
      expect(
        VenueTimezone.offsetFor('America/New_York', summerUtc),
        const Duration(hours: -4),
      );

      // January is Standard Time (EST = UTC-5)
      final winterUtc = DateTime.utc(2026, 1, 15, 12, 0);
      expect(
        VenueTimezone.offsetFor('America/New_York', winterUtc),
        const Duration(hours: -5),
      );
    });

    test('Phoenix does not observe daylight saving time', () {
      final summerUtc = DateTime.utc(2026, 7, 15, 12, 0);
      final winterUtc = DateTime.utc(2026, 1, 15, 12, 0);
      expect(
        VenueTimezone.offsetFor('America/Phoenix', summerUtc),
        const Duration(hours: -7),
      );
      expect(
        VenueTimezone.offsetFor('America/Phoenix', winterUtc),
        const Duration(hours: -7),
      );
    });

    test('Europe/London observes British Summer Time', () {
      // July BST = UTC+1
      final summerUtc = DateTime.utc(2026, 7, 15, 12, 0);
      expect(
        VenueTimezone.offsetFor('Europe/London', summerUtc),
        const Duration(hours: 1),
      );

      // January GMT = UTC+0
      final winterUtc = DateTime.utc(2026, 1, 15, 12, 0);
      expect(
        VenueTimezone.offsetFor('Europe/London', winterUtc),
        Duration.zero,
      );
    });

    test('Australia/Sydney observes Southern Hemisphere daylight saving', () {
      // January AEDT = UTC+11
      final janUtc = DateTime.utc(2026, 1, 15, 12, 0);
      expect(
        VenueTimezone.offsetFor('Australia/Sydney', janUtc),
        const Duration(hours: 11),
      );

      // July AEST = UTC+10
      final julUtc = DateTime.utc(2026, 7, 15, 12, 0);
      expect(
        VenueTimezone.offsetFor('Australia/Sydney', julUtc),
        const Duration(hours: 10),
      );
    });

    test('toVenueTime and toUtc round trip', () {
      const tz = 'America/Chicago';
      final utcInstant = DateTime.utc(2026, 10, 10, 23, 30);
      final venueWallClock = VenueTimezone.toVenueTime(utcInstant, tz);

      // 23:30 UTC in October (CDT = UTC-5) is 18:30 wall clock
      expect(venueWallClock.hour, 18);
      expect(venueWallClock.minute, 30);

      final roundTripUtc = VenueTimezone.toUtc(venueWallClock, tz);
      expect(roundTripUtc, utcInstant);
    });

    test('businessDateFor boundary respects startHour', () {
      const tz = 'America/New_York'; // EDT = UTC-4 in October

      // 09:00 UTC = 05:00 EDT (before 6 AM startHour -> belongs to Oct 9)
      final earlyMorning = DateTime.utc(2026, 10, 10, 9, 0);
      final bizDateEarly =
          VenueTimezone.businessDateFor(earlyMorning, tz, startHour: 6);
      expect(bizDateEarly, DateTime.utc(2026, 10, 9));

      // 11:00 UTC = 07:00 EDT (after 6 AM startHour -> belongs to Oct 10)
      final morning = DateTime.utc(2026, 10, 10, 11, 0);
      final bizDateMorning =
          VenueTimezone.businessDateFor(morning, tz, startHour: 6);
      expect(bizDateMorning, DateTime.utc(2026, 10, 10));
    });

    test('formatting helpers format correctly in venue timezone', () {
      const tz = 'America/New_York'; // EDT = UTC-4 in October
      final utcInstant = DateTime.utc(2026, 10, 10, 23, 0); // 7:00 PM EDT

      expect(VenueTimezone.formatTime(utcInstant, tz), '7:00 PM');
      expect(VenueTimezone.formatShortDate(utcInstant, tz), 'Oct 10, 2026');
      expect(VenueTimezone.formatDayAndDate(utcInstant, tz), 'Sat, Oct 10');
    });
  });
}
