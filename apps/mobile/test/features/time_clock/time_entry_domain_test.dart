import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/time_entry.dart';

TimeEntry _entry({
  required DateTime clockIn,
  DateTime? clockOut,
  List<TimeBreak> breaks = const [],
}) =>
    TimeEntry(
      id: 'e1',
      organizationId: 'o',
      venueId: 'v',
      userId: 'u',
      clockInAt: clockIn,
      clockInLat: 0,
      clockInLng: 0,
      clockInAccuracyM: 10,
      clockOutAt: clockOut,
      isOpen: clockOut == null,
      breaks: breaks,
      createdAt: clockIn,
      updatedAt: clockIn,
    );

void main() {
  final day = DateTime(2026, 10, 6, 9);

  group('netWorkedMinutesWithin', () {
    test('an 8-hour punch with a 30-minute unpaid break nets 7.5 hours', () {
      final entry = _entry(
        clockIn: day,
        clockOut: day.add(const Duration(hours: 8)),
        breaks: [
          TimeBreak(
            type: 'unpaid',
            startAt: day.add(const Duration(hours: 4)),
            endAt: day.add(const Duration(hours: 4, minutes: 30)),
          ),
        ],
      );
      final minutes = entry.netWorkedMinutesWithin(
        day.subtract(const Duration(days: 1)),
        day.add(const Duration(days: 1)),
      );
      expect(minutes, 7 * 60 + 30);
    });

    test('a paid break is not subtracted', () {
      final entry = _entry(
        clockIn: day,
        clockOut: day.add(const Duration(hours: 8)),
        breaks: [
          TimeBreak(
            type: 'paid',
            startAt: day.add(const Duration(hours: 4)),
            endAt: day.add(const Duration(hours: 4, minutes: 30)),
          ),
        ],
      );
      final minutes = entry.netWorkedMinutesWithin(
        day.subtract(const Duration(days: 1)),
        day.add(const Duration(days: 1)),
      );
      expect(minutes, 8 * 60);
    });

    test('an unpaid break overlapping the window boundary is clipped', () {
      final weekEnd = day.add(const Duration(hours: 5));
      final entry = _entry(
        clockIn: day,
        clockOut: day.add(const Duration(hours: 8)),
        breaks: [
          TimeBreak(
            // Break starts an hour before the window ends and runs 2 hours past it —
            // only the 1 hour inside the window should be subtracted.
            type: 'unpaid',
            startAt: day.add(const Duration(hours: 4)),
            endAt: day.add(const Duration(hours: 6)),
          ),
        ],
      );
      final minutes = entry.netWorkedMinutesWithin(day, weekEnd);
      // Worked window: 0..5h = 300min. Break overlap within window: 4..5h = 60min.
      expect(minutes, 300 - 60);
    });

    test('an open entry (no clock-out) nets against now, never negative', () {
      final entry = _entry(clockIn: DateTime.now());
      final minutes = entry.netWorkedMinutesWithin(
        DateTime.now().subtract(const Duration(days: 1)),
        DateTime.now().add(const Duration(days: 1)),
      );
      expect(minutes, greaterThanOrEqualTo(0));
    });

    test('an open unpaid break (still running) is subtracted up to now', () {
      final start = DateTime.now().subtract(const Duration(hours: 2));
      final breakStart = DateTime.now().subtract(const Duration(minutes: 20));
      final entry = _entry(
        clockIn: start,
        breaks: [TimeBreak(type: 'unpaid', startAt: breakStart)],
      );
      final minutes = entry.netWorkedMinutesWithin(
        start.subtract(const Duration(days: 1)),
        DateTime.now().add(const Duration(days: 1)),
      );
      // ~2h worked minus ~20min still-open unpaid break ≈ 100 minutes; allow slack for
      // the moment-of-test drift between the two DateTime.now() calls above.
      expect(minutes, inInclusiveRange(95, 105));
    });

    test('entirely outside the window nets zero', () {
      final entry = _entry(
        clockIn: day,
        clockOut: day.add(const Duration(hours: 8)),
      );
      final minutes = entry.netWorkedMinutesWithin(
        day.add(const Duration(days: 10)),
        day.add(const Duration(days: 11)),
      );
      expect(minutes, 0);
    });
  });
}
