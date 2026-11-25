import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/time_clock/presentation/time_review_screen.dart';
import 'package:venuewrangler_mobile/features/venues/presentation/venue_time_widgets.dart';

void main() {
  test('correctionDaysBack reaches the clock-in day, never less than 1', () {
    final now = DateTime.utc(2026, 11, 25, 9, 30);
    expect(correctionDaysBack(now, DateTime.utc(2026, 11, 25, 6)), 1);
    expect(correctionDaysBack(now, DateTime.utc(2026, 11, 24, 23)), 1);
    expect(correctionDaysBack(now, DateTime.utc(2026, 11, 20, 23, 59)), 5);
    expect(correctionDaysBack(now, DateTime.utc(2026, 9, 10, 18)), 76);
    // Across a month and year boundary.
    expect(correctionDaysBack(now, DateTime.utc(2025, 12, 31, 22)), 329);
  });

  testWidgets(
      'a punch from weeks ago can be corrected on its own day (picker is not capped at yesterday)',
      (tester) async {
    final nowWall = DateTime.utc(2026, 11, 25, 12);
    final clockInWall = DateTime.utc(2026, 9, 10, 9);
    final clockOutWall = DateTime.utc(2026, 9, 10, 17);

    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () => pickVenueDateTime(
              context,
              initial: clockOutWall,
              nowWall: nowWall,
              daysBack: correctionDaysBack(nowWall, clockInWall),
            ),
            child: const Text('Correct'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Correct'));
    await tester.pumpAndSettle();

    final picker = tester.widget<DatePickerDialog>(
      find.byType(DatePickerDialog),
    );
    expect(picker.initialDate, DateTime(2026, 9, 10));
    expect(picker.firstDate.isAfter(DateTime(2026, 9, 10)), isFalse);
  });
}
