import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/crm/domain/beo_time.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_beo.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_clock.dart';

void main() {
  const chicago = VenueClock('America/Chicago');
  const losAngeles = VenueClock('America/Los_Angeles');

  group('BEO times use the venue clock (launch review D6)', () {
    test('7:00 PM booked for a Chicago venue is 7:00 PM wherever it is read',
        () {
      // The owner, in Los Angeles, picks Fri Nov 20 2026 7:00 PM on the venue's clock.
      final instant = chicago.instant(DateTime.utc(2026, 11, 20, 19));
      expect(instant, DateTime.utc(2026, 11, 21, 1)); // CST, UTC-6
      expect(beoWhenLabel(instant, chicago), 'Fri, Nov 20 7:00 PM');
      // The same instant read on a Los Angeles clock would be 5:00 PM: the label must never
      // use anything but the venue's zone.
      expect(beoWhenLabel(instant, losAngeles), 'Fri, Nov 20 5:00 PM');
    });

    test('the offset follows DST on the event date, not on today', () {
      // Sat Oct 31 2026 is still daylight time in Chicago (UTC-5) ...
      final beforeFallBack = chicago.instant(DateTime.utc(2026, 10, 31, 19));
      expect(beforeFallBack, DateTime.utc(2026, 11, 1, 0));
      // ... Sun Nov 1 2026 is standard time (UTC-6).
      final afterFallBack = chicago.instant(DateTime.utc(2026, 11, 1, 19));
      expect(afterFallBack, DateTime.utc(2026, 11, 2, 1));
      expect(beoWhenLabel(beforeFallBack, chicago), 'Sat, Oct 31 7:00 PM');
      expect(beoWhenLabel(afterFallBack, chicago), 'Sun, Nov 1 7:00 PM');

      // Spring forward: Sun Mar 8 2026 7:00 PM is daylight time (UTC-5).
      final spring = chicago.instant(DateTime.utc(2026, 3, 8, 19));
      expect(spring, DateTime.utc(2026, 3, 9, 0));
      expect(beoWhenLabel(spring, chicago), 'Sun, Mar 8 7:00 PM');
    });

    test('the default start is 6:00 PM on the venue calendar 30 days out', () {
      expect(
        defaultBeoStartWall(DateTime.utc(2026, 12, 15, 23, 40)),
        DateTime.utc(2027, 1, 14, 18),
      );
    });
  });

  group('CrmBeo.canRestoreAt', () {
    CrmBeo beo(String status, DateTime? date) => CrmBeo(
          id: 'b',
          venueId: 'v',
          eventName: 'Party',
          eventDate: date,
          status: status,
          createdAt: DateTime.utc(2026),
          updatedAt: DateTime.utc(2026),
        );
    final now = DateTime.utc(2026, 10, 22);

    test('only a cancelled BEO whose date has not passed', () {
      final dec = DateTime.utc(2026, 12, 11);
      expect(beo('cancelled', dec).canRestoreAt(now), isTrue);
      expect(beo('cancelled', null).canRestoreAt(now), isTrue);
      final past = DateTime.utc(2026, 10, 1);
      expect(beo('cancelled', past).canRestoreAt(now), isFalse);
      expect(beo('confirmed', dec).canRestoreAt(now), isFalse);
    });

    test('reads the cancellation fields the database maintains', () {
      final parsed = CrmBeo.fromJson({
        'id': 'b',
        'venue_id': 'v',
        'event_name': 'Party',
        'status': 'cancelled',
        'cancelled_at': '2026-10-20T15:00:00+00:00',
        'status_before_cancel': 'confirmed',
        'created_at': '2026-10-01T00:00:00+00:00',
        'updated_at': '2026-10-20T15:00:00+00:00',
      });
      expect(parsed.cancelledAt, DateTime.utc(2026, 10, 20, 15));
      expect(parsed.statusBeforeCancel, 'confirmed');
    });
  });
}
