import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_timezone.dart';

void main() {
  test('reservation and event wall-clock entry displays the time that is saved',
      () {
    final wall = DateTime.utc(2026, 10, 14, 15);
    expect(VenueTimezone.formatWallTime(wall), '3:00 PM');
    expect(VenueTimezone.formatWallDate(wall), 'Oct 14, 2026');
    final stored = VenueTimezone.toUtc(wall, 'America/Chicago');
    expect(stored, DateTime.utc(2026, 10, 14, 20));
    expect(VenueTimezone.formatTime(stored, 'America/Chicago'), '3:00 PM');
  });
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

    test('America/Los_Angeles switches DST at 02:00 local, per its own offset',
        () {
      // 2026: DST starts Sunday 8 March (02:00 PST = 10:00 UTC) and ends Sunday 1 November
      // (02:00 PDT = 09:00 UTC).
      const tz = 'America/Los_Angeles';
      expect(
        VenueTimezone.offsetFor(tz, DateTime.utc(2026, 3, 8, 9, 59)),
        const Duration(hours: -8),
      );
      expect(
        VenueTimezone.offsetFor(tz, DateTime.utc(2026, 3, 8, 10, 0)),
        const Duration(hours: -7),
      );
      expect(
        VenueTimezone.offsetFor(tz, DateTime.utc(2026, 11, 1, 8, 59)),
        const Duration(hours: -7),
      );
      expect(
        VenueTimezone.offsetFor(tz, DateTime.utc(2026, 11, 1, 9, 0)),
        const Duration(hours: -8),
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

  group('VenueTimezone.toUtc across DST transitions', () {
    test('Los Angeles spring-forward day resolves with the daylight offset',
        () {
      // DST starts 2026-03-08 at 02:00 PST (10:00Z).
      expect(
        VenueTimezone.toUtc(DateTime.utc(2026, 3, 8, 6), 'America/Los_Angeles'),
        DateTime.utc(2026, 3, 8, 13),
      );
    });

    test('New York spring-forward day resolves with the daylight offset', () {
      // DST starts 2026-03-08 at 02:00 EST (07:00Z).
      expect(
        VenueTimezone.toUtc(
          DateTime.utc(2026, 3, 8, 3, 30),
          'America/New_York',
        ),
        DateTime.utc(2026, 3, 8, 7, 30),
      );
    });

    test('a wall time in the spring-forward gap resolves to the later instant',
        () {
      // 02:30 does not exist on 2026-03-08 in Los Angeles; it reads as 03:30 PDT.
      expect(
        VenueTimezone.toUtc(
          DateTime.utc(2026, 3, 8, 2, 30),
          'America/Los_Angeles',
        ),
        DateTime.utc(2026, 3, 8, 10, 30),
      );
    });

    test(
        'Los Angeles fall-back day: the ambiguous hour takes the earlier instant',
        () {
      // 01:30 happens twice on 2026-11-01; the first occurrence is PDT (08:30Z).
      expect(
        VenueTimezone.toUtc(
          DateTime.utc(2026, 11, 1, 1, 30),
          'America/Los_Angeles',
        ),
        DateTime.utc(2026, 11, 1, 8, 30),
      );
      // After the transition at 09:00Z, the same wall hour is PST.
      expect(
        VenueTimezone.toUtc(
          DateTime.utc(2026, 11, 1, 6),
          'America/Los_Angeles',
        ),
        DateTime.utc(2026, 11, 1, 14),
      );
    });

    test('New York fall-back day round trips through toVenueTime', () {
      final wall = DateTime.utc(2026, 11, 1, 12);
      final utc = VenueTimezone.toUtc(wall, 'America/New_York');
      expect(utc, DateTime.utc(2026, 11, 1, 17));
      expect(VenueTimezone.toVenueTime(utc, 'America/New_York'), wall);
    });

    test('Phoenix (no DST) is a fixed -7 offset on both transition days', () {
      expect(
        VenueTimezone.toUtc(DateTime.utc(2026, 3, 8, 6), 'America/Phoenix'),
        DateTime.utc(2026, 3, 8, 13),
      );
      expect(
        VenueTimezone.toUtc(DateTime.utc(2026, 11, 1, 6), 'America/Phoenix'),
        DateTime.utc(2026, 11, 1, 13),
      );
    });

    test('Honolulu (no DST) is a fixed -10 offset', () {
      expect(
        VenueTimezone.toUtc(DateTime.utc(2026, 3, 8, 6), 'Pacific/Honolulu'),
        DateTime.utc(2026, 3, 8, 16),
      );
      expect(
        VenueTimezone.toUtc(DateTime.utc(2026, 11, 1, 6), 'Pacific/Honolulu'),
        DateTime.utc(2026, 11, 1, 16),
      );
    });

    test('an unknown timezone id falls back to UTC', () {
      expect(
        VenueTimezone.toUtc(DateTime.utc(2026, 6, 1, 12), 'Mars/Olympus_Mons'),
        DateTime.utc(2026, 6, 1, 12),
      );
    });

    test('EU summer time starts at the transition instant itself', () {
      // London switches at 01:00Z on the last Sunday of March (2026-03-29).
      expect(
        VenueTimezone.offsetFor('Europe/London', DateTime.utc(2026, 3, 29, 1)),
        const Duration(hours: 1),
      );
      expect(
        VenueTimezone.offsetFor(
          'Europe/London',
          DateTime.utc(2026, 3, 29, 0, 59, 59),
        ),
        Duration.zero,
      );
    });
  });
}
