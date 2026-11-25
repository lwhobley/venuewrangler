import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/integrations/application/brighthr_providers.dart';
import 'package:venuewrangler_mobile/features/integrations/data/brighthr_repository.dart';
import 'package:venuewrangler_mobile/features/integrations/domain/brighthr_models.dart';
import 'package:venuewrangler_mobile/features/integrations/presentation/brighthr_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/workforce/application/workforce_providers.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

const _venueId = 'venue-1';

class _FakeBrightHrRepository implements BrightHrRepository {
  _FakeBrightHrRepository({this.connection, this.connectError});

  BrightHrConnection? connection;
  final AppError? connectError;
  final connects = <(String, String, String)>[];
  final links = <(String, String?)>[];
  var employees = <BrightHrEmployee>[
    const BrightHrEmployee(
      externalEmployeeId: 'bhr-1',
      givenName: 'Ada',
      familyName: 'Lovelace',
      jobTitle: 'Bartender',
    ),
  ];

  @override
  Future<BrightHrConnection?> fetchConnection(String venueId) async =>
      connection;

  @override
  Future<List<BrightHrEmployee>> fetchEmployees(String connectionId) async =>
      employees;

  @override
  Future<List<BrightHrAbsence>> fetchUpcomingAbsences(
    String connectionId,
  ) async =>
      [
        BrightHrAbsence(
          externalAbsenceId: 'a1',
          externalEmployeeId: 'bhr-1',
          type: BrightHrAbsenceType.holiday,
          startDate: DateTime(2030, 1, 2),
          startPart: 'FullDay',
          endDate: DateTime(2030, 1, 4),
          endPart: 'FullDay',
        ),
      ];

  @override
  Future<List<BrightHrClocking>> fetchRecentClockings(
    String connectionId,
  ) async =>
      const [];

  @override
  Future<void> connect({
    required String venueId,
    required String clientId,
    required String clientSecret,
  }) async {
    final error = connectError;
    if (error != null) throw error;
    connects.add((venueId, clientId, clientSecret));
    connection = BrightHrConnection(
      id: 'conn-1',
      venueId: venueId,
      status: 'connected',
      clientId: clientId,
    );
  }

  @override
  Future<void> link({
    required String venueId,
    required String externalEmployeeId,
    required String? staffId,
  }) async {
    links.add((externalEmployeeId, staffId));
    employees = [
      for (final e in employees)
        e.externalEmployeeId == externalEmployeeId
            ? BrightHrEmployee(
                externalEmployeeId: e.externalEmployeeId,
                givenName: e.givenName,
                familyName: e.familyName,
                jobTitle: e.jobTitle,
                linkedStaffId: staffId,
              )
            : e,
    ];
  }

  @override
  Future<void> syncNow(String venueId) async {}

  @override
  Future<void> disconnect(String venueId) async => connection = null;
}

Widget _app(_FakeBrightHrRepository repository) {
  return ProviderScope(
    overrides: [
      brightHrRepositoryProvider.overrideWithValue(repository),
      activeVenueProvider.overrideWith(
        (ref) => Venue(
          id: _venueId,
          organizationId: 'org-1',
          name: 'The Lounge',
          createdAt: DateTime(2026),
        ),
      ),
      rosterForVenueProvider(_venueId).overrideWith(
        (ref) async => const [
          RosterMember(userId: 'user-1', role: 'staff', displayName: 'Ada L.'),
        ],
      ),
    ],
    child: const MaterialApp(home: BrightHrScreen()),
  );
}

void main() {
  test('BrightHrAbsence parses date-only values without a time zone shift', () {
    final absence = BrightHrAbsence.fromJson({
      'external_absence_id': 'a1',
      'external_employee_id': 'e1',
      'absence_type': 'Toil',
      'display_name': null,
      'start_date': '2026-12-24',
      'start_part': 'SecondHalf',
      'end_date': '2026-12-26',
      'end_part': 'FullDay',
    });
    expect(absence.startDate, DateTime(2026, 12, 24));
    expect(absence.type, BrightHrAbsenceType.toil);
    expect(absence.label, 'TOIL');
    expect(absence.covers(DateTime(2026, 12, 25, 23, 59)), isTrue);
    expect(absence.covers(DateTime(2026, 12, 27)), isFalse);
  });

  test('BrightHrConnection masks the client id', () {
    const connection = BrightHrConnection(
      id: 'c',
      venueId: 'v',
      status: 'connected',
      clientId: 'abcdef123456',
    );
    expect(connection.maskedClientId, '••••3456');
  });

  test('function errors map to actionable messages', () {
    expect(
      mapBrightHrFunctionError(400, {'error': 'brighthr_invalid_credentials'})
          .message,
      contains('did not accept'),
    );
    expect(
      mapBrightHrFunctionError(403, {'error': 'not_a_venue_manager'}),
      isA<PermissionDeniedError>(),
    );
    expect(mapBrightHrFunctionError(502, null), isA<UnknownError>());
  });

  testWidgets('connects with pasted credentials and shows imported data',
      (tester) async {
    final repository = _FakeBrightHrRepository();
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    expect(find.text('Connect BrightHR'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextField, 'Client ID'),
      'client-123',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Client Secret'),
      's3cret',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(repository.connects, [(_venueId, 'client-123', 's3cret')]);
    expect(find.text('Ada Lovelace'), findsOneWidget);
    expect(find.text('Not linked'), findsOneWidget);
    expect(find.textContaining('0 of 1 linked'), findsOneWidget);
  });

  testWidgets('shows the BrightHR error instead of connecting', (tester) async {
    final repository = _FakeBrightHrRepository(
      connectError: const UnknownError('BrightHR did not accept that.'),
    );
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Client ID'), 'x');
    await tester.enterText(
      find.widgetWithText(TextField, 'Client Secret'),
      'y',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Connect'));
    await tester.pumpAndSettle();

    expect(find.text('BrightHR did not accept that.'), findsOneWidget);
    expect(find.text('Connect BrightHR'), findsOneWidget);
  });

  testWidgets('links a BrightHR employee to a team member', (tester) async {
    final repository = _FakeBrightHrRepository(
      connection: const BrightHrConnection(
        id: 'conn-1',
        venueId: _venueId,
        status: 'connected',
        clientId: 'client-123',
      ),
    );
    await tester.pumpWidget(_app(repository));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ada Lovelace'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ada L.'));
    await tester.pumpAndSettle();

    expect(repository.links, [('bhr-1', 'user-1')]);
    expect(find.textContaining('1 of 1 linked'), findsOneWidget);

    await tester.tap(find.text('Absences'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Holiday'), findsOneWidget);
  });
}
