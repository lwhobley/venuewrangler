import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/files/text_file_saver.dart';
import 'package:venuewrangler_mobile/features/time_clock/application/timesheet_providers.dart';
import 'package:venuewrangler_mobile/features/time_clock/data/timesheet_repository.dart';
import 'package:venuewrangler_mobile/features/time_clock/domain/timesheet.dart';
import 'package:venuewrangler_mobile/features/time_clock/presentation/hours_review_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeTimesheetRepository implements TimesheetRepository {
  _FakeTimesheetRepository(this.entries);

  List<TimesheetEntry> entries;
  final corrections = <({String id, DateTime at, String reason})>[];

  @override
  Future<List<ClockBoardRow>> fetchClockBoard(String venueId) async => [];

  @override
  Future<List<TimesheetEntry>> fetchTimesheet({
    required String venueId,
    required DateTime from,
    required DateTime to,
  }) async =>
      entries;

  @override
  Future<void> correctClockOut({
    required String timeEntryId,
    required DateTime clockOutAt,
    required String reason,
  }) async {
    corrections.add((id: timeEntryId, at: clockOutAt, reason: reason));
    entries = [
      for (final e in entries)
        e.id == timeEntryId
            ? TimesheetEntry(
                id: e.id,
                userId: e.userId,
                displayName: e.displayName,
                clockInAt: e.clockInAt,
                clockOutAt: clockOutAt,
                isOpen: false,
                clockInAttested: true,
                clockOutAttested: true,
                corrections: [
                  TimeCorrection(
                    correctedAt: DateTime.now(),
                    correctedBy: 'manager-1',
                    correctedByName: 'Morgan',
                    reason: reason,
                  ),
                ],
              )
            : e,
    ];
  }
}

class _FakeSaver implements TextFileSaver {
  String? fileName;
  String? contents;

  @override
  Future<bool> save({
    required String fileName,
    required String contents,
    String mimeType = 'text/csv',
  }) async {
    this.fileName = fileName;
    this.contents = contents;
    return true;
  }
}

void main() {
  final venue = Venue(
    id: 'v1',
    organizationId: 'o1',
    name: 'Fulton & Pine',
    timezone: 'America/Chicago',
    latitude: 41.88,
    longitude: -87.65,
    createdAt: DateTime(2026),
  );

  Future<(_FakeTimesheetRepository, _FakeSaver)> pump(
    WidgetTester tester,
  ) async {
    final start = DateTime.now().toUtc().subtract(const Duration(hours: 10));
    final repo = _FakeTimesheetRepository([
      TimesheetEntry(
        id: 'closed',
        userId: 'colin-1',
        displayName: 'Colin Park',
        clockInAt: start,
        clockOutAt: start.add(const Duration(hours: 7, minutes: 45)),
        isOpen: false,
        clockInAttested: true,
        clockOutAttested: true,
      ),
      TimesheetEntry(
        id: 'open',
        userId: 'gemma-1',
        displayName: 'Gemma Line',
        clockInAt: start,
        isOpen: true,
        clockInAttested: true,
      ),
    ]);
    final saver = _FakeSaver();
    tester.view.physicalSize = const Size(900, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          currentUserIdProvider.overrideWithValue('manager-1'),
          timesheetRepositoryProvider.overrideWithValue(repo),
          textFileSaverProvider.overrideWithValue(saver),
        ],
        child: const MaterialApp(home: HoursReviewScreen()),
      ),
    );
    await tester.pumpAndSettle();
    return (repo, saver);
  }

  testWidgets('shows hours per person by name and the missed clock-out',
      (tester) async {
    await pump(tester);

    expect(find.text('Colin Park'), findsOneWidget);
    expect(find.text('7:45'), findsWidgets);
    expect(find.text('Still clocked in'), findsOneWidget);
    expect(find.text('Gemma Line'), findsWidgets);
    expect(find.textContaining('America/Chicago'), findsOneWidget);
  });

  testWidgets('a manager closes a missed clock-out with a reason',
      (tester) async {
    final (repo, _) = await pump(tester);

    await tester.tap(find.widgetWithText(TextButton, 'Close'));
    await tester.pumpAndSettle();
    expect(find.text('Close missed clock-out'), findsOneWidget);

    // Without a time or a reason it stays open and says why.
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();
    expect(find.text('Choose the clock-out time'), findsWidgets);
    expect(find.text('Say why you are changing this punch'), findsOneWidget);
    expect(repo.corrections, isEmpty);

    await tester.tap(find.byKey(const ValueKey('pick-clock-out')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // date
    await tester.pumpAndSettle();
    await tester.tap(find.text('OK')); // time
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const ValueKey('correction-reason')),
      'Forgot to clock out',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Save'));
    await tester.pumpAndSettle();

    expect(repo.corrections, hasLength(1));
    expect(repo.corrections.single.id, 'open');
    expect(repo.corrections.single.reason, 'Forgot to clock out');
    expect(find.text('Still clocked in'), findsNothing);
    expect(find.text('Punch updated.'), findsOneWidget);
  });

  testWidgets('exports punches as CSV in venue time', (tester) async {
    final (_, saver) = await pump(tester);

    await tester.tap(find.byTooltip('Export for payroll'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Export punches (CSV)'));
    await tester.pumpAndSettle();

    expect(saver.fileName, startsWith('fulton-pine-hours-'));
    expect(saver.contents, contains('Colin Park'));
    expect(saver.contents, contains('America/Chicago'));
    expect(saver.contents, contains('7.75'));
    expect(saver.contents, contains('Open (missing clock-out)'));
  });
}
