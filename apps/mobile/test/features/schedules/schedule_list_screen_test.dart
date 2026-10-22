import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/schedules/application/schedules_providers.dart';
import 'package:venuewrangler_mobile/features/schedules/data/schedules_repository.dart';
import 'package:venuewrangler_mobile/features/schedules/domain/shift.dart';
import 'package:venuewrangler_mobile/features/schedules/presentation/schedule_list_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venue_clock.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/workforce/domain/workforce_models.dart';

class _Repo implements SchedulesRepository {
  _Repo(this.shifts, {this.swaps = const []});

  final List<Shift> shifts;
  final List<ShiftSwap> swaps;
  final created =
      <({String? staffId, String? role, DateTime start, DateTime end})>[];
  final claims = <({String swapId, bool allowOverlap})>[];
  final approvals = <({String swapId, bool allowOverlap})>[];
  PostgrestException? createError;

  @override
  Future<List<Shift>> fetchShiftsForVenue(String venueId) async => shifts;

  @override
  Future<List<ShiftSwap>> fetchSwapsForVenue(String venueId) async => swaps;

  @override
  Stream<void> watchScheduleChanges(String venueId) => const Stream.empty();

  @override
  Future<ShiftSwapStatus> claimSwap({
    required String swapId,
    bool allowOverlap = false,
  }) async {
    claims.add((swapId: swapId, allowOverlap: allowOverlap));
    return ShiftSwapStatus.claimed;
  }

  @override
  Future<void> approveSwap({
    required String swapId,
    bool allowOverlap = false,
  }) async {
    approvals.add((swapId: swapId, allowOverlap: allowOverlap));
  }

  @override
  Future<void> createShift({
    required String venueId,
    String? staffId,
    String? roleLabel,
    String? section,
    required DateTime startTime,
    required DateTime endTime,
  }) async {
    if (createError != null) throw createError!;
    created.add(
      (staffId: staffId, role: roleLabel, start: startTime, end: endTime),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _alice = RosterMember(
  userId: 'alice-id',
  role: 'staff',
  displayName: 'Alice Adams',
);

class _Ai implements AiRepository {
  _Ai(this.answer);

  /// What suggestScheduling returns, or throws when it is an [AppError].
  final Object answer;
  String? lastInput;

  @override
  Future<SchedulingSuggestionResult> suggestScheduling({
    required String venueId,
    required String context,
  }) async {
    lastInput = context;
    final a = answer;
    if (a is AppError) throw a;
    return a as SchedulingSuggestionResult;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

const _ingrid = RosterMember(
  userId: 'ingrid-id',
  role: 'staff',
  displayName: 'Ingrid Ortega',
);
const _jada = RosterMember(
  userId: 'jada-id',
  role: 'staff',
  displayName: 'Jada Echols',
);

Future<_Repo> _pump(
  WidgetTester tester, {
  String timezone = 'America/Chicago',
  List<Shift> shifts = const [],
  List<ShiftSwap> swaps = const [],
  String me = 'boss',
  bool manager = true,
  AiRepository? ai,
}) async {
  tester.view.physicalSize = const Size(900, 1600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final repo = _Repo(shifts, swaps: swaps);
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org',
    name: 'Venue',
    timezone: timezone,
    createdAt: DateTime(2026),
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        activeVenueProvider.overrideWith((ref) => venue),
        schedulesRepositoryProvider.overrideWithValue(repo),
        canManageActiveVenueProvider.overrideWith((ref) async => manager),
        currentUserIdProvider.overrideWithValue(me),
        scheduleRosterForVenueProvider.overrideWith(
          (ref, venueId) async => const [_alice, _ingrid, _jada],
        ),
        if (ai != null) aiRepositoryProvider.overrideWithValue(ai),
      ],
      child: const MaterialApp(home: ScheduleListScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return repo;
}

void main() {
  testWidgets('Add shift offers a roster picker, not a typed user id',
      (tester) async {
    final repo = await _pump(tester);

    await tester.tap(find.text('Add shift'));
    await tester.pumpAndSettle();

    expect(find.textContaining('Staff user ID'), findsNothing);
    expect(find.text('Assigned to'), findsOneWidget);

    await tester.tap(find.byType(DropdownButtonFormField<String?>));
    await tester.pumpAndSettle();
    expect(find.text('Open shift (unassigned)'), findsWidgets);
    await tester.tap(find.text('Alice Adams').last);
    await tester.pumpAndSettle();

    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final saved = repo.created.single;
    expect(saved.staffId, 'alice-id');
    expect(saved.start.isUtc, isTrue);
    expect(saved.end.difference(saved.start), const Duration(hours: 4));
  });

  testWidgets(
      'the saved start is the venue clock reading, not the device clock',
      (tester) async {
    final repo = await _pump(tester, timezone: 'Africa/Johannesburg');
    const clock = VenueClock('Africa/Johannesburg');
    final before = clock.now;

    await tester.tap(find.text('Add shift'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final start = repo.created.single.start;
    final wall = clock.wall(start);
    // The dialog's default start is "now" on the venue's wall clock.
    expect(wall.difference(before).inMinutes.abs(), lessThanOrEqualTo(2));
    expect(repo.created.single.staffId, isNull); // open shift
  });

  testWidgets('shifts are listed in venue time with the person named',
      (tester) async {
    const clock = VenueClock('Africa/Johannesburg');
    final start = clock.instant(DateTime.utc(2026, 10, 20, 9));
    await _pump(
      tester,
      timezone: 'Africa/Johannesburg',
      shifts: [
        Shift(
          id: 's1',
          venueId: 'venue-1',
          staffId: 'alice-id',
          roleLabel: 'Bartender',
          startTime: start,
          endTime: start.add(const Duration(hours: 4)),
          status: ShiftStatus.scheduled,
        ),
      ],
    );

    expect(find.textContaining('Oct 20, 2026 9:00 AM'), findsOneWidget);
    expect(find.textContaining('Staff: Alice Adams'), findsOneWidget);
  });

  testWidgets('an unsupported zone shows the banner and blocks Add shift',
      (tester) async {
    final repo = await _pump(tester, timezone: 'Mars/Olympus_Mons');

    expect(
      find.byKey(const ValueKey('unsupported-timezone-banner')),
      findsOneWidget,
    );

    await tester.tap(find.text('Add shift'));
    await tester.pumpAndSettle();

    expect(find.text('Assigned to'), findsNothing);
    expect(find.textContaining("isn't supported"), findsWidgets);
    expect(repo.created, isEmpty);
  });

  group('swaps (launch review U1)', () {
    // Thu Oct 22, 2026 in Chicago: Ingrid's server shift 4:30-10:30 PM and Jada's bar shift
    // 4 PM-12:30 AM.
    const clock = VenueClock('America/Chicago');
    final serverStart = clock.instant(DateTime.utc(2026, 10, 22, 16, 30));
    final server = Shift(
      id: 'server',
      venueId: 'venue-1',
      staffId: 'ingrid-id',
      roleLabel: 'Server',
      section: 'main',
      startTime: serverStart,
      endTime: serverStart.add(const Duration(hours: 6)),
      status: ShiftStatus.scheduled,
    );
    final barStart = clock.instant(DateTime.utc(2026, 10, 22, 16));
    final bar = Shift(
      id: 'bar',
      venueId: 'venue-1',
      staffId: 'jada-id',
      roleLabel: 'Bartender',
      startTime: barStart,
      endTime: barStart.add(const Duration(hours: 8, minutes: 30)),
      status: ShiftStatus.scheduled,
    );
    ShiftSwap swap({
      ShiftSwapStatus status = ShiftSwapStatus.pending,
      String? acceptedBy,
    }) =>
        ShiftSwap(
          id: 'swap-1',
          venueId: 'venue-1',
          shiftId: 'server',
          requestedBy: 'ingrid-id',
          status: status,
          acceptedBy: acceptedBy,
        );

    testWidgets('an offer names the day, time and role of the shift',
        (tester) async {
      await _pump(
        tester,
        shifts: [server, bar],
        swaps: [swap()],
        me: 'jada-id',
        manager: false,
      );

      expect(find.text('Thu Oct 22 · Server · main'), findsOneWidget);
      expect(find.text('4:30 PM – 10:30 PM'), findsOneWidget);
      expect(
        find.text('Offered by Ingrid Ortega · open to anyone'),
        findsOneWidget,
      );
    });

    testWidgets('taking confirms who and what, and warns about a clash',
        (tester) async {
      final repo = await _pump(
        tester,
        shifts: [server, bar],
        swaps: [swap()],
        me: 'jada-id',
        manager: false,
      );

      await tester.tap(find.widgetWithText(FilledButton, 'Take shift'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          "Take Ingrid Ortega's Thu Oct 22 Server shift, 4:30 PM – 10:30 PM?",
        ),
        findsOneWidget,
      );
      expect(find.textContaining('You already work Bartender'), findsOneWidget);
      expect(repo.claims, isEmpty);

      await tester.tap(find.widgetWithText(FilledButton, 'Take shift anyway'));
      await tester.pumpAndSettle();

      expect(repo.claims.single, (swapId: 'swap-1', allowOverlap: true));
      expect(find.textContaining('A manager will approve it'), findsOneWidget);
    });

    testWidgets('a manager approves for the teammate instead of taking it',
        (tester) async {
      final repo = await _pump(
        tester,
        shifts: [server],
        swaps: [swap(status: ShiftSwapStatus.claimed, acceptedBy: 'jada-id')],
      );

      expect(
        find.textContaining('Jada Echols is taking it · awaiting manager'),
        findsOneWidget,
      );
      expect(find.widgetWithText(FilledButton, 'Take shift'), findsNothing);
      await tester.tap(
        find.widgetWithText(FilledButton, 'Approve for Jada Echols'),
      );
      await tester.pumpAndSettle();
      expect(
        find.text(
          "Give Ingrid Ortega's Thu Oct 22 Server shift, 4:30 PM – 10:30 PM "
          'to Jada Echols?',
        ),
        findsOneWidget,
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Approve'));
      await tester.pumpAndSettle();

      expect(repo.approvals.single, (swapId: 'swap-1', allowOverlap: false));
      expect(repo.claims, isEmpty);
    });
  });

  group('dialogs keep what was entered', () {
    testWidgets('a refused Add shift stays open with the reason',
        (tester) async {
      final repo = await _pump(tester)
        ..createError = const PostgrestException(message: 'no', code: '42501');

      await tester.tap(find.text('Add shift'));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'Role (e.g. bartender)'),
        'Host',
      );
      await tester.tap(find.widgetWithText(FilledButton, 'Add'));
      await tester.pumpAndSettle();

      expect(
        find.text("You don't have permission to schedule shifts here."),
        findsOneWidget,
      );
      expect(find.text('Host'), findsOneWidget);
      expect(repo.created, isEmpty);
    });

    testWidgets('Suggest coverage explains an empty or failed request in place',
        (tester) async {
      final ai = _Ai(const AiUnavailableError('AI is off for this venue.'));
      await _pump(tester, ai: ai);

      await tester.tap(find.text('Suggest coverage'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Suggest'));
      await tester.pumpAndSettle();
      expect(
        find.text('Describe the shifts that need coverage first.'),
        findsOneWidget,
      );
      expect(ai.lastInput, isNull);

      await tester.enterText(find.byType(TextField), 'Need a busser Sunday');
      await tester.tap(find.widgetWithText(FilledButton, 'Suggest'));
      await tester.pumpAndSettle();
      expect(find.text('AI is off for this venue.'), findsOneWidget);
      expect(find.text('Need a busser Sunday'), findsOneWidget);
    });
  });

  testWidgets(
      'adding a coverage suggestion prefills the suggested person '
      '(launch review U8)', (tester) async {
    final ai = _Ai(
      const SchedulingSuggestionResult([
        ShiftSuggestion(
          staffId: 'staff_2',
          staffName: 'Ingrid Ortega',
          roleLabel: 'Busser',
          startTime: '2026-10-25T09:30',
          endTime: '2026-10-25T15:00',
          reason: 'Trained to bus and free Sunday',
        ),
      ]),
    );
    final repo = await _pump(tester, ai: ai);

    await tester.tap(find.text('Suggest coverage'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Busser Sunday brunch');
    await tester.tap(find.widgetWithText(FilledButton, 'Suggest'));
    await tester.pumpAndSettle();

    // The assistant was told today's venue date and given roster keys, not user ids.
    expect(ai.lastInput, contains('Today is '));
    expect(ai.lastInput, contains('staff_id: staff_2 | name: Ingrid Ortega'));
    expect(ai.lastInput, isNot(contains('ingrid-id')));

    expect(find.text('Ingrid Ortega'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Add'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Add'));
    await tester.pumpAndSettle();

    final saved = repo.created.single;
    expect(saved.staffId, 'ingrid-id');
    expect(saved.role, 'Busser');
    expect(
      const VenueClock('America/Chicago').wall(saved.start),
      DateTime.utc(2026, 10, 25, 9, 30),
    );
  });
}
