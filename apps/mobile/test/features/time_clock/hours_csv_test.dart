import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/time_review_repository.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/time_entry.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_clock.dart';

void main() {
  test('payroll exports names, venue times, net hours and safe CSV cells', () {
    final start = DateTime.utc(2026, 10, 20, 22);
    final entry = TimeEntry(
      id: 'entry',
      organizationId: 'org',
      venueId: 'venue',
      userId: 'user',
      clockInAt: start,
      clockOutAt: start.add(const Duration(hours: 8)),
      isOpen: false,
      breaks: [
        TimeBreak(
          type: 'unpaid',
          startAt: start.add(const Duration(hours: 4)),
          endAt: start.add(const Duration(hours: 4, minutes: 30)),
        ),
      ],
      createdAt: start,
      updatedAt: start,
    );
    final csv = hoursCsv(
      [entry],
      {'user': '=IMPORTDATA("bad")'},
      const VenueClock('America/Chicago').formatDateTime,
    );
    expect(csv, contains('"7.50"'));
    expect(csv, contains('5:00 PM'));
    expect(csv, contains("\"'=IMPORTDATA(\"\"bad\"\")\""));
    expect(csv, contains('"Closed"'));
  });
}
