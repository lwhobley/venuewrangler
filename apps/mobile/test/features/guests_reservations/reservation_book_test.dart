import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/domain/hold_conflict.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/domain/reservation.dart';
import 'package:venuewrangler_mobile/features/guests_reservations/domain/reservation_book.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_clock.dart';

Reservation _r(String id, DateTime at) => Reservation(
      id: id,
      organizationId: 'o',
      venueId: 'v',
      guestName: id,
      partySize: 2,
      reservationTime: at,
      createdAt: DateTime.utc(2026),
      updatedAt: DateTime.utc(2026),
    );

void main() {
  const tz = 'America/Chicago';
  // Venue wall times in Chicago during CDT (UTC-5).
  DateTime cdt(int month, int day, int hour, [int minute = 0]) =>
      DateTime.utc(2026, month, day, hour + 5, minute);

  group('reservationBook (launch review U6)', () {
    final today = DateTime.utc(2026, 10, 20); // Tue, Oct 20

    test('each night lists the earliest booking first', () {
      final book = reservationBook(
        [
          _r('nine', cdt(10, 21, 21)),
          _r('eight-fifteen', cdt(10, 21, 20, 15)),
          _r('six-thirty', cdt(10, 21, 18, 30)),
        ],
        tz,
        today: today,
      );
      expect(book, hasLength(1));
      expect(book.single.night, DateTime.utc(2026, 10, 21));
      expect(
        book.single.reservations.map((r) => r.id),
        ['six-thirty', 'eight-fifteen', 'nine'],
      );
    });

    test('a booking after midnight stays under the night it belongs to', () {
      final book = reservationBook(
        [
          _r('late', cdt(10, 21, 2, 21)), // Wed 2:21 AM -> Tuesday's book
          _r('dinner', cdt(10, 20, 19, 45)),
          _r('wednesday', cdt(10, 21, 18)),
        ],
        tz,
        today: today,
      );
      expect(book.map((n) => formatNight(n.night)), [
        'Tue, Oct 20',
        'Wed, Oct 21',
      ]);
      expect(book.first.reservations.map((r) => r.id), ['dinner', 'late']);
    });

    test('tonight and later come first, soonest first, then past nights', () {
      final book = reservationBook(
        [
          _r('dec', DateTime.utc(2026, 12, 12, 1)),
          _r('lastweek', cdt(10, 13, 19)),
          _r('tomorrow', cdt(10, 21, 19)),
          _r('yesterday', cdt(10, 19, 19)),
          _r('tonight', cdt(10, 20, 19)),
        ],
        tz,
        today: today,
      );
      expect(
        book.map((n) => n.reservations.single.id),
        ['tonight', 'tomorrow', 'dec', 'yesterday', 'lastweek'],
      );
    });

    test('ties keep a stable order', () {
      final book = reservationBook(
        [_r('b', cdt(10, 20, 19)), _r('a', cdt(10, 20, 19))],
        tz,
        today: today,
      );
      expect(book.single.reservations.map((r) => r.id), ['a', 'b']);
    });
  });

  group('hold conflicts name what is in the way (launch review U7)', () {
    const clock = VenueClock(tz);

    test('dinner reservations blocking an event are named as reservations', () {
      final conflict = HoldConflict.parse(
        '{"total": 3, "conflicts": ['
        '{"kind": "reservation", "name": "Lee", "party_size": 2, '
        '"starts_at": "2026-10-25T00:30:00+00:00", '
        '"ends_at": "2026-10-25T02:00:00+00:00"}, '
        '{"kind": "reservation", "name": "Okafor", "party_size": 4, '
        '"starts_at": "2026-10-25T02:00:00+00:00", '
        '"ends_at": "2026-10-25T03:30:00+00:00"}]}',
      );
      expect(conflict.total, 3);
      expect(conflict.hasEvent, isFalse);
      expect(
        describeHoldConflict(conflict, clock, subject: 'This event'),
        'This event on Oct 24, 2026 overlaps reservations: Lee at 7:30 PM, '
        '2 guests; Okafor at 9:00 PM, 4 guests, and 1 more. A confirmed event '
        'holds the venue for four hours.',
      );
    });

    test('a booking blocked by a private event names the event and window', () {
      final conflict = HoldConflict.parse(
        '{"total": 1, "conflicts": [{"kind": "event", '
        '"name": "Caroline Whitmore", "party_size": 45, '
        '"starts_at": "2026-12-12T01:00:00+00:00", '
        '"ends_at": "2026-12-12T05:00:00+00:00"}]}',
      );
      expect(
        describeHoldConflict(conflict, clock, subject: 'This time'),
        'This time on Dec 11, 2026 overlaps the private event '
        '"Caroline Whitmore" (7:00 PM–11:00 PM, 45 guests).',
      );
    });

    test('a missing or malformed detail never blames an event', () {
      for (final details in [null, '', 'not json', '{"conflicts": 3}']) {
        final conflict = HoldConflict.parse(details);
        expect(conflict.items, isEmpty);
        expect(
          describeHoldConflict(conflict, clock, subject: 'This event'),
          'This event overlaps another booking. Choose another time.',
        );
      }
    });
  });
}
