import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/ai/application/ai_providers.dart';
import 'package:venuewrangler_mobile/features/ai/data/ai_repository.dart';
import 'package:venuewrangler_mobile/features/ai/domain/ai_models.dart';
import 'package:venuewrangler_mobile/features/crm/application/crm_providers.dart';
import 'package:venuewrangler_mobile/features/crm/data/crm_repository.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_beo.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_lead.dart';
import 'package:venuewrangler_mobile/features/crm/domain/enquiry_import.dart';
import 'package:venuewrangler_mobile/features/crm/presentation/enquiry_import_dialog.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_clock.dart';

class _Ai extends Fake implements AiRepository {
  _Ai({this.result, this.error});

  final EventEnquiryResult? result;
  final Object? error;
  String? lastInput;

  @override
  Future<EventEnquiryResult> parseEventEnquiry({
    required String venueId,
    required String enquiryText,
  }) async {
    lastInput = enquiryText;
    final e = error;
    if (e != null) throw e;
    return result!;
  }
}

class _Crm extends Fake implements CrmRepository {
  /// Errors thrown by the next call of each write, then cleared.
  Object? failLead;
  Object? failNote;
  Object? failBeo;
  final leads = <({String name, String? email, int? cents, String? source})>[];
  final notes = <String>[];
  final beos = <({String name, DateTime? date, int? guests, String? leadId})>[];

  @override
  Future<CrmLead> createLead({
    required String venueId,
    required String fullName,
    String? email,
    String? phone,
    String? company,
    String? source,
    int? estimatedValueCents,
  }) async {
    final e = failLead;
    failLead = null;
    if (e != null) throw e;
    leads.add(
      (
        name: fullName,
        email: email,
        cents: estimatedValueCents,
        source: source,
      ),
    );
    final now = DateTime.utc(2026, 10, 24);
    return CrmLead.fromJson({
      'id': 'lead-${leads.length}',
      'venue_id': venueId,
      'full_name': fullName,
      'status': 'new',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
  }

  @override
  Future<void> addNote({required String leadId, required String text}) async {
    final e = failNote;
    failNote = null;
    if (e != null) throw e;
    notes.add(text);
  }

  @override
  Future<CrmBeo> createBeo({
    required String venueId,
    String? leadId,
    required String eventName,
    DateTime? eventDate,
    int? guestCount,
    String? venueSpace,
  }) async {
    final e = failBeo;
    failBeo = null;
    if (e != null) throw e;
    beos.add(
      (name: eventName, date: eventDate, guests: guestCount, leadId: leadId),
    );
    final now = DateTime.utc(2026, 10, 24);
    return CrmBeo(
      id: 'beo-1',
      venueId: venueId,
      eventName: eventName,
      status: 'draft',
      createdAt: now,
      updatedAt: now,
    );
  }
}

const _clock = VenueClock('UTC');

final _caroline = EventEnquiryResult(
  contactName: 'Caroline Whitmore',
  contactEmail: 'caroline@example.com',
  eventName: 'Whitmore party',
  eventDate: DateTime.utc(2026, 12, 11),
  startMinutes: 18 * 60,
  endMinutes: 23 * 60,
  guestCount: 45,
  budgetUsd: 3000,
  requestedItems: const ['Buffet', 'Open bar until 11'],
  uncertain: const {'event_name'},
  missing: const ['Dietary needs', 'Phone number'],
);

const _pasted =
    '45 people, Dec 11, buffet, open bar till 11, contact Caroline Whitmore '
    'caroline@example.com';

Future<ValueNotifier<bool?>> _open(
  WidgetTester tester, {
  required _Ai ai,
  required _Crm crm,
}) async {
  tester.view.physicalSize = const Size(800, 3000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  final result = ValueNotifier<bool?>(null);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        aiRepositoryProvider.overrideWithValue(ai),
        crmRepositoryProvider.overrideWithValue(crm),
      ],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () async {
                  result.value = await showDialog<bool>(
                    context: context,
                    builder: (_) =>
                        const EnquiryImportDialog(venueId: 'v', clock: _clock),
                  );
                },
                child: const Text('Open'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open'));
  await tester.pumpAndSettle();
  return result;
}

String _text(WidgetTester tester, String key) => tester
    .widget<TextField>(find.byKey(ValueKey('enquiry-$key')))
    .controller!
    .text;

void main() {
  group('helpers', () {
    test('AI input carries the venue date and fences the pasted text', () {
      final input = enquiryAiInput('  hello  ', DateTime.utc(2026, 10, 24));
      expect(input, contains('Today (venue local date) is 2026-10-24.'));
      expect(input, contains('"""\nhello\n"""'));
    });

    test('AI input is capped', () {
      final input = enquiryAiInput('x' * 20000, DateTime.utc(2026, 1, 2));
      expect(input.length, lessThan(kMaxEnquiryChars + 200));
      expect(input, contains('2026-01-02'));
    });

    test('the lead note lists what was confirmed and what is missing', () {
      final note = buildEnquiryNote(
        eventName: 'Whitmore party',
        eventType: 'Birthday',
        eventDate: DateTime.utc(2026, 12, 11),
        startMinutes: 18 * 60,
        endMinutes: 23 * 60,
        guestCount: 45,
        budgetUsd: 3500.5,
        requestedItems: const ['Buffet', 'Open bar'],
        notes: 'Quiet corner please',
        missing: const ['Dietary needs'],
      );
      expect(note, contains('Event: Whitmore party (Birthday)'));
      expect(
        note,
        contains('When (venue time): Dec 11, 2026, 6:00 PM to 11:00 PM'),
      );
      expect(note, contains('Guests: 45'));
      expect(note, contains('Budget: \$3,500.50'));
      expect(note, contains('Requested: Buffet; Open bar'));
      expect(note, contains('Notes: Quiet corner please'));
      expect(note, contains('Still to ask the client: Dietary needs'));
    });

    test('the note leaves out what was not given', () {
      final note = buildEnquiryNote(eventName: 'Party');
      expect(note, isNot(contains('Guests')));
      expect(note, isNot(contains('Budget')));
      expect(note, isNot(contains('When')));
    });
  });

  group('EnquiryImportDialog', () {
    testWidgets(
        'AI result prefills the form, highlights unsure fields, '
        'and creates the lead and BEO on confirm', (tester) async {
      final ai = _Ai(result: _caroline);
      final crm = _Crm();
      final result = await _open(tester, ai: ai, crm: crm);

      await tester.enterText(find.byType(TextField), _pasted);
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();

      expect(ai.lastInput, contains(_pasted));
      expect(ai.lastInput, contains('Today (venue local date) is'));
      expect(_text(tester, 'contact_name'), 'Caroline Whitmore');
      expect(_text(tester, 'contact_email'), 'caroline@example.com');
      expect(_text(tester, 'guest_count'), '45');
      expect(_text(tester, 'budget_usd'), '3000');
      expect(_text(tester, 'requested_items'), 'Buffet\nOpen bar until 11');
      expect(find.text('Dec 11, 2026'), findsOneWidget);
      expect(find.text('6:00 PM'), findsOneWidget);
      expect(find.text('11:00 PM'), findsOneWidget);
      // Only the field the AI was unsure about is flagged.
      expect(find.text('Check this: the AI was not sure.'), findsOneWidget);
      expect(find.text('Still to ask the client'), findsOneWidget);
      expect(find.text('• Dietary needs'), findsOneWidget);
      // Nothing is created before confirming.
      expect(crm.leads, isEmpty);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(crm.leads.single.name, 'Caroline Whitmore');
      expect(crm.leads.single.email, 'caroline@example.com');
      expect(crm.leads.single.cents, 300000);
      expect(crm.leads.single.source, 'Enquiry');
      expect(crm.notes.single, contains('Still to ask the client'));
      expect(crm.notes.single, contains('6:00 PM to 11:00 PM'));
      expect(crm.beos.single.name, 'Whitmore party');
      expect(crm.beos.single.date, DateTime.utc(2026, 12, 11, 18));
      expect(crm.beos.single.guests, 45);
      expect(crm.beos.single.leadId, 'lead-1');
      expect(result.value, isTrue);
      expect(find.text('Check the enquiry'), findsNothing);
    });

    testWidgets('editing an unsure field clears its highlight', (tester) async {
      await _open(tester, ai: _Ai(result: _caroline), crm: _Crm());
      await tester.enterText(find.byType(TextField), _pasted);
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('enquiry-event_name')),
        'Whitmore 40th',
      );
      await tester.pump();
      expect(find.text('Check this: the AI was not sure.'), findsNothing);
    });

    testWidgets('the BEO can be turned off, and needs a name and start time',
        (tester) async {
      final crm = _Crm();
      await _open(
        tester,
        ai: _Ai(
          result: EventEnquiryResult(
            contactName: 'Sam',
            eventDate: DateTime.utc(2026, 12, 11),
          ),
        ),
        crm: crm,
      );
      await tester.enterText(find.byType(TextField), _pasted);
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Name the event to create a BEO.'), findsOneWidget);
      expect(find.text('Pick a start time to create a BEO.'), findsOneWidget);
      expect(crm.leads, isEmpty);

      await tester.ensureVisible(find.text('Also create a BEO draft'));
      await tester.tap(find.text('Also create a BEO draft'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(crm.leads.single.name, 'Sam');
      expect(crm.beos, isEmpty);
    });

    testWidgets('AI unavailable keeps the paste and offers the manual form',
        (tester) async {
      final ai = _Ai(
        error: const AiUnavailableError(
          'AI features are turned off for this organization.',
        ),
      );
      final crm = _Crm();
      final result = await _open(tester, ai: ai, crm: crm);

      await tester.enterText(find.byType(TextField), _pasted);
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();

      expect(
        find.text('AI features are turned off for this organization.'),
        findsOneWidget,
      );
      expect(find.text(_pasted), findsOneWidget);

      await tester.tap(find.text('Fill in by hand'));
      await tester.pumpAndSettle();
      expect(find.text('Check the enquiry'), findsOneWidget);
      expect(_text(tester, 'contact_name'), '');

      await tester.enterText(
        find.byKey(const ValueKey('enquiry-contact_name')),
        'Sam Rivera',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(crm.leads.single.name, 'Sam Rivera');
      expect(crm.beos, isEmpty);
      expect(result.value, isTrue);
    });

    testWidgets('an unexpected AI failure keeps the pasted text',
        (tester) async {
      await _open(tester, ai: _Ai(error: StateError('boom')), crm: _Crm());
      await tester.enterText(find.byType(TextField), _pasted);
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();

      expect(
        find.text('Something went wrong reading that message.'),
        findsOneWidget,
      );
      expect(find.text(_pasted), findsOneWidget);
      expect(find.text('Read with AI'), findsOneWidget);
    });

    testWidgets('a blank paste is refused without calling AI', (tester) async {
      final ai = _Ai(result: _caroline);
      await _open(tester, ai: ai, crm: _Crm());
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();
      expect(find.text('Paste the email or message first.'), findsOneWidget);
      expect(ai.lastInput, isNull);
    });

    testWidgets('a refused save keeps every field and the dialog open',
        (tester) async {
      final crm = _Crm()
        ..failLead = const PostgrestException(message: 'denied', code: '42501');
      final result = await _open(tester, ai: _Ai(result: _caroline), crm: crm);
      await tester.enterText(find.byType(TextField), _pasted);
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('enquiry-notes')),
        'My own note',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(
        find.text("You don't have permission to create this here."),
        findsOneWidget,
      );
      expect(find.text('Check the enquiry'), findsOneWidget);
      expect(_text(tester, 'contact_name'), 'Caroline Whitmore');
      expect(_text(tester, 'notes'), 'My own note');
      expect(result.value, isNull);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(crm.leads, hasLength(1));
      expect(result.value, isTrue);
    });

    testWidgets('a failure after the lead exists never duplicates the lead',
        (tester) async {
      final crm = _Crm()..failBeo = Exception('offline');
      final result = await _open(tester, ai: _Ai(result: _caroline), crm: crm);
      await tester.enterText(find.byType(TextField), _pasted);
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.textContaining('The lead was created'), findsOneWidget);
      expect(crm.leads, hasLength(1));
      expect(crm.notes, hasLength(1));
      expect(crm.beos, isEmpty);
      expect(result.value, isNull);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(crm.leads, hasLength(1));
      expect(crm.notes, hasLength(1));
      expect(crm.beos, hasLength(1));
      expect(result.value, isTrue);
    });

    testWidgets('invalid fields are flagged and nothing is saved',
        (tester) async {
      final crm = _Crm();
      await _open(
        tester,
        ai: _Ai(result: const EventEnquiryResult()),
        crm: crm,
      );
      await tester.enterText(find.byType(TextField), _pasted);
      await tester.tap(find.text('Read with AI'));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.byKey(const ValueKey('enquiry-contact_email')),
        'nope',
      );
      await tester.enterText(
        find.byKey(const ValueKey('enquiry-guest_count')),
        '0',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();

      expect(find.text("Enter the contact's name."), findsOneWidget);
      expect(
        find.text('Enter a valid email or leave it blank.'),
        findsOneWidget,
      );
      expect(find.text('Enter a whole number of guests.'), findsOneWidget);
      expect(crm.leads, isEmpty);
    });
  });
}
