import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/features/crm/application/crm_providers.dart';
import 'package:venuewrangler_mobile/features/crm/data/crm_repository.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_beo.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_beo_charge.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_contract.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_lead.dart';
import 'package:venuewrangler_mobile/features/crm/presentation/crm_form_dialogs.dart';
import 'package:venuewrangler_mobile/features/crm/presentation/crm_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeCrmRepository implements CrmRepository {
  _FakeCrmRepository({List<CrmBeo>? beos, List<CrmBeoCharge>? charges})
      : _beos = beos ?? [],
        _charges = charges ?? [];

  final List<CrmBeo> _beos;
  final List<CrmBeoCharge> _charges;

  /// Thrown by the next write that consults it (then cleared), to simulate a refused save.
  Object? failNextWrite;
  final statusUpdates = <({String beoId, String status})>[];
  final restored = <String>[];
  final createdLeads = <String>[];
  final createdBeos = <({String name, DateTime? eventDate})>[];
  final notes = <String>[];

  void _maybeFail() {
    final error = failNextWrite;
    failNextWrite = null;
    if (error != null) throw error;
  }

  @override
  Future<List<CrmLead>> getLeads({
    required String venueId,
    String? search,
    int limit = 100,
  }) async =>
      [];

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
    _maybeFail();
    createdLeads.add(fullName);
    final now = DateTime.utc(2026, 10, 7);
    return CrmLead.fromJson({
      'id': 'lead-new',
      'venue_id': venueId,
      'full_name': fullName,
      'status': 'new',
      'created_at': now.toIso8601String(),
      'updated_at': now.toIso8601String(),
    });
  }

  @override
  Future<void> updateLeadStatus({
    required String leadId,
    required String status,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<CrmNote>> getNotes({required String leadId}) async => [];

  @override
  Future<void> addNote({required String leadId, required String text}) async {
    _maybeFail();
    notes.add(text);
  }

  @override
  Future<List<CrmActivityLogEntry>> getActivity({
    required String leadId,
    int limit = 50,
  }) async =>
      [];

  @override
  Future<List<CrmBeo>> getBeos({
    required String venueId,
    int limit = 100,
  }) async =>
      _beos;

  @override
  Future<CrmBeo> createBeo({
    required String venueId,
    String? leadId,
    required String eventName,
    DateTime? eventDate,
    int? guestCount,
    String? venueSpace,
  }) async {
    _maybeFail();
    createdBeos.add((name: eventName, eventDate: eventDate));
    final now = DateTime.utc(2026, 10, 7);
    return CrmBeo(
      id: 'beo-new',
      venueId: venueId,
      eventName: eventName,
      eventDate: eventDate,
      status: 'draft',
      createdAt: now,
      updatedAt: now,
    );
  }

  @override
  Future<void> updateBeoStatus({
    required String beoId,
    required String status,
  }) async {
    _maybeFail();
    statusUpdates.add((beoId: beoId, status: status));
  }

  @override
  Future<String> restoreBeo({required String beoId}) async {
    _maybeFail();
    restored.add(beoId);
    return 'confirmed';
  }

  @override
  Future<List<CrmBeoCharge>> getBeoCharges({required String beoId}) async =>
      _charges;

  @override
  Future<void> addBeoCharge({
    required String beoId,
    required String venueId,
    required String description,
    required String category,
    required int amountCents,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> deleteBeoCharge({required String chargeId}) =>
      throw UnimplementedError();

  @override
  Future<({String contractId, bool alreadyExisted})> convertBeoToContract({
    required String beoId,
  }) =>
      throw UnimplementedError();

  List<CrmContract> contracts = [];
  final signatures =
      <({String contractId, String name, bool fully, String? note})>[];

  @override
  Future<List<CrmContract>> getContracts({
    required String venueId,
    int limit = 100,
  }) async =>
      contracts;

  @override
  Future<void> updateContractStatus({
    required String contractId,
    required String status,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> recordContractSignature({
    required String contractId,
    required String signerName,
    bool fullySigned = true,
    String? note,
  }) async {
    signatures.add(
      (
        contractId: contractId,
        name: signerName,
        fully: fullySigned,
        note: note
      ),
    );
  }

  @override
  Future<List<CrmForecastRow>> getForecast({required String venueId}) async =>
      [];

  @override
  Future<List<CrmStaleLead>> getStaleLeads({
    required String venueId,
    int days = 5,
  }) async =>
      [];

  @override
  Future<void> sendTemplateEmail({
    required String templateId,
    String? leadId,
    String? beoId,
    required String to,
  }) =>
      throw UnimplementedError();
}

void main() {
  final testVenue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime.now(),
  );

  testWidgets('shows an empty state when the venue has no BEOs',
      (tester) async {
    final fakeRepo = _FakeCrmRepository(beos: []);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          crmRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: CrmScreen()),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('BEOs'));
    await tester.pumpAndSettle();

    expect(find.text('No BEOs yet.'), findsOneWidget);
  });

  testWidgets('opens a formatted BEO with details and recorded charges',
      (tester) async {
    final now = DateTime.utc(2026, 10, 7);
    final fakeRepo = _FakeCrmRepository(
      beos: [
        CrmBeo(
          id: 'beo-1',
          venueId: testVenue.id,
          eventName: 'Founders Dinner',
          eventDate: now,
          eventType: 'Private dinner',
          guestCount: 40,
          venueSpace: 'Main dining',
          setupStyle: 'Banquet rounds',
          fbMinimumCents: 200000,
          menuAppetizers: 'Passed canapés',
          menuEntrees: 'Steak and mushroom risotto',
          menuDesserts: 'Chocolate tart',
          menuBarPackage: 'Hosted bar',
          specialRequirements: 'Nut-free table',
          internalNotes: 'Vendor load-in at 16:00',
          status: 'confirmed',
          createdAt: now,
          updatedAt: now,
        ),
      ],
      charges: [
        CrmBeoCharge(
          id: 'charge-1',
          beoId: 'beo-1',
          venueId: testVenue.id,
          description: 'Dinner package',
          category: 'food',
          amountCents: 250000,
        ),
        CrmBeoCharge(
          id: 'charge-2',
          beoId: 'beo-1',
          venueId: testVenue.id,
          description: 'Courtesy discount',
          category: 'discount',
          amountCents: 10000,
        ),
      ],
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          crmRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: CrmScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('BEOs'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Founders Dinner'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View BEO'));
    await tester.pumpAndSettle();

    expect(find.text('Banquet event order'), findsOneWidget);
    expect(find.text('Passed canapés'), findsOneWidget);
    expect(find.text('Nut-free table'), findsOneWidget);
    expect(find.text('Dinner package'), findsOneWidget);
    expect(find.text('Courtesy discount'), findsOneWidget);
    expect(find.text('\$2,400.00'), findsOneWidget);
    expect(
      find.text('The minimum is a commitment, not an additional charge.'),
      findsOneWidget,
    );
  });

  testWidgets('signed states are only offered through the signature action',
      (tester) async {
    final now = DateTime.utc(2026, 10, 7);
    final fakeRepo = _FakeCrmRepository(beos: [])
      ..contracts = [
        CrmContract(
          id: 'contract-1',
          venueId: testVenue.id,
          contractNumber: 'CT-1',
          eventName: 'Gala',
          status: 'sent',
          createdAt: now,
          updatedAt: now,
        ),
      ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          crmRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: CrmScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contracts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();

    expect(find.text('Record client signature…'), findsOneWidget);
    expect(find.text('fully_signed'), findsNothing);
    expect(find.text('partially_signed'), findsNothing);
    expect(find.text('cancelled'), findsOneWidget);
  });

  testWidgets('recording a signature sends the signer and the evidence note',
      (tester) async {
    final now = DateTime.utc(2026, 10, 7);
    final fakeRepo = _FakeCrmRepository(beos: [])
      ..contracts = [
        CrmContract(
          id: 'contract-1',
          venueId: testVenue.id,
          contractNumber: 'CT-1',
          status: 'sent',
          createdAt: now,
          updatedAt: now,
        ),
      ];

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => testVenue),
          crmRepositoryProvider.overrideWithValue(fakeRepo),
        ],
        child: const MaterialApp(home: CrmScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Contracts'));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(PopupMenuButton<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Record client signature…'));
    await tester.pumpAndSettle();

    // A too-short name is rejected before anything is sent.
    await tester.enterText(
      find.widgetWithText(TextField, 'Signer full name'),
      'x',
    );
    await tester.tap(find.text('Record signature'));
    await tester.pumpAndSettle();
    expect(fakeRepo.signatures, isEmpty);
    expect(find.text("Enter the signer's full name."), findsOneWidget);

    await tester.enterText(
      find.widgetWithText(TextField, 'Signer full name'),
      'Pat Client',
    );
    await tester.enterText(
      find.widgetWithText(TextField, 'Note (optional, e.g. signed in person)'),
      'signed in person',
    );
    await tester.tap(find.text('Record signature'));
    await tester.pumpAndSettle();

    expect(
      fakeRepo.signatures.single,
      (
        contractId: 'contract-1',
        name: 'Pat Client',
        fully: true,
        note: 'signed in person',
      ),
    );
  });

  group('BEO cancel, restore and venue time', () {
    final chicago = Venue(
      id: 'venue-1',
      organizationId: 'org-1',
      name: 'Marigold',
      timezone: 'America/Chicago',
      createdAt: DateTime.utc(2026),
    );
    final now = DateTime.utc(2026, 10, 7);

    CrmBeo whitmore({String status = 'confirmed', DateTime? eventDate}) =>
        CrmBeo(
          id: 'beo-w',
          venueId: chicago.id,
          eventName: 'Whitmore & Associates Holiday Party',
          // Fri Dec 11 2026, 7:00 PM in Chicago (CST, UTC-6).
          eventDate: eventDate ?? DateTime.utc(2026, 12, 12, 1),
          guestCount: 45,
          status: status,
          createdAt: now,
          updatedAt: now,
        );

    Future<void> openBeos(WidgetTester tester, _FakeCrmRepository repo) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeVenueProvider.overrideWith((ref) => chicago),
            crmRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: CrmScreen()),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('BEOs'));
      await tester.pumpAndSettle();
    }

    testWidgets('shows the BEO start on the venue clock', (tester) async {
      await openBeos(tester, _FakeCrmRepository(beos: [whitmore()]));
      expect(
        find.text('confirmed · Fri, Dec 11 7:00 PM · 45 guests'),
        findsOneWidget,
      );
    });

    testWidgets('cancel asks first, naming guests and charges', (tester) async {
      final repo = _FakeCrmRepository(
        beos: [whitmore()],
        charges: [
          CrmBeoCharge(
            id: 'c1',
            beoId: 'beo-w',
            venueId: chicago.id,
            description: 'Dinner package',
            category: 'food',
            amountCents: 644000,
          ),
        ],
      );
      await openBeos(tester, repo);
      await tester.tap(find.text('Whitmore & Associates Holiday Party'));
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();
      expect(
        find.text('Cancel Whitmore & Associates Holiday Party?'),
        findsOneWidget,
      );
      expect(
        find.textContaining(
          'Fri, Dec 11 7:00 PM · 45 guests · \$6,440.00 in charges',
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Keep event'));
      await tester.pumpAndSettle();
      expect(repo.statusUpdates, isEmpty);

      await tester.tap(find.widgetWithText(OutlinedButton, 'Cancel'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel event'));
      await tester.pumpAndSettle();
      expect(repo.statusUpdates.single, (beoId: 'beo-w', status: 'cancelled'));
      expect(find.text('Undo'), findsOneWidget);

      await tester.tap(find.text('Undo'));
      await tester.pumpAndSettle();
      expect(repo.restored, ['beo-w']);
    });

    testWidgets('a cancelled future BEO can be restored; a past one cannot',
        (tester) async {
      final repo = _FakeCrmRepository(
        beos: [
          whitmore(status: 'cancelled', eventDate: DateTime.utc(2099, 1, 1)),
        ],
      );
      await openBeos(tester, repo);
      await tester.tap(find.text('Whitmore & Associates Holiday Party'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Restore'));
      await tester.pumpAndSettle();
      expect(repo.restored, ['beo-w']);

      final past = _FakeCrmRepository(
        beos: [
          whitmore(status: 'cancelled', eventDate: DateTime.utc(2020, 1, 1)),
        ],
      );
      await openBeos(tester, past);
      await tester.tap(find.text('Whitmore & Associates Holiday Party'));
      await tester.pumpAndSettle();
      expect(find.text('Restore'), findsNothing);
    });

    testWidgets('a refused confirm names the dinner bookings in the way',
        (tester) async {
      final repo = _FakeCrmRepository(
        beos: [
          CrmBeo(
            id: 'beo-p',
            venueId: chicago.id,
            eventName: 'Patel Birthday',
            eventDate: DateTime.utc(2026, 10, 25),
            guestCount: 20,
            status: 'draft',
            createdAt: now,
            updatedAt: now,
          ),
        ],
      )..failNextWrite = const PostgrestException(
          message: 'reservation_hold_conflict: 2 reservations overlap the '
              'requested event window',
          code: '23505',
          details: '{"total": 2, "conflicts": ['
              '{"kind": "reservation", "name": "Lee", "party_size": 2, '
              '"starts_at": "2026-10-25T00:30:00+00:00", '
              '"ends_at": "2026-10-25T02:00:00+00:00"}, '
              '{"kind": "reservation", "name": "Okafor", "party_size": 4, '
              '"starts_at": "2026-10-25T02:00:00+00:00", '
              '"ends_at": "2026-10-25T03:30:00+00:00"}]}',
        );
      await openBeos(tester, repo);
      await tester.tap(find.text('Patel Birthday'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Confirm'));
      await tester.pumpAndSettle();

      expect(
        find.text(
          'This event on Oct 24, 2026 overlaps reservations: '
          'Lee at 7:30 PM, 2 guests; Okafor at 9:00 PM, 4 guests. '
          'A confirmed event holds the venue for four hours.',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('another confirmed event'), findsNothing);
    });
  });

  group('CRM forms keep what was typed until saved', () {
    Future<_FakeCrmRepository> pump(WidgetTester tester, {String? tab}) async {
      final repo = _FakeCrmRepository();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            activeVenueProvider.overrideWith((ref) => testVenue),
            crmRepositoryProvider.overrideWithValue(repo),
          ],
          child: const MaterialApp(home: CrmScreen()),
        ),
      );
      await tester.pumpAndSettle();
      if (tab != null) {
        await tester.tap(find.text(tab));
        await tester.pumpAndSettle();
      }
      return repo;
    }

    testWidgets('new lead: a blank name and a failed save stay open',
        (tester) async {
      final repo = await pump(tester);
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Company (optional)'),
        'Whitmore & Associates',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text("Enter the lead's name."), findsOneWidget);
      expect(find.text('Whitmore & Associates'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Full name'),
        'Caroline Whitmore',
      );
      repo.failNextWrite = Exception('offline');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('New lead'), findsOneWidget);
      expect(
        find.text('Could not create this lead. Check your connection and '
            'try again.'),
        findsOneWidget,
      );
      expect(find.text('Caroline Whitmore'), findsOneWidget);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(repo.createdLeads, ['Caroline Whitmore']);
      expect(find.text('New lead'), findsNothing);
    });

    testWidgets('new BEO: a blank name and a failed save stay open',
        (tester) async {
      final repo = await pump(tester, tab: 'BEOs');
      await tester.tap(find.byType(FloatingActionButton));
      await tester.pumpAndSettle();

      await tester.enterText(
        find.widgetWithText(TextField, 'Guest count (optional)'),
        '30',
      );
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('Enter a name for the event.'), findsOneWidget);

      await tester.enterText(
        find.widgetWithText(TextField, 'Event name'),
        'Okafor Retirement Dinner',
      );
      repo.failNextWrite = Exception('offline');
      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(find.text('New BEO'), findsOneWidget);
      expect(find.text('Okafor Retirement Dinner'), findsOneWidget);
      expect(find.text('30'), findsOneWidget);

      await tester.tap(find.text('Create'));
      await tester.pumpAndSettle();
      expect(repo.createdBeos.single.name, 'Okafor Retirement Dinner');
      expect(find.text('New BEO'), findsNothing);
    });

    testWidgets('lead note: a blank note and a failed save stay open',
        (tester) async {
      final repo = _FakeCrmRepository();
      bool? result;
      await tester.pumpWidget(
        ProviderScope(
          overrides: [crmRepositoryProvider.overrideWithValue(repo)],
          child: MaterialApp(
            home: Builder(
              builder: (context) => TextButton(
                onPressed: () async => result = await showDialog<bool>(
                  context: context,
                  builder: (_) => const AddLeadNoteDialog(leadId: 'lead-1'),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Write the note first.'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'Prefers the patio');
      repo.failNextWrite = Exception('offline');
      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(find.text('Add note'), findsOneWidget);
      expect(find.text('Prefers the patio'), findsOneWidget);
      expect(find.textContaining('Could not add this note'), findsOneWidget);

      await tester.tap(find.text('Add'));
      await tester.pumpAndSettle();
      expect(repo.notes, ['Prefers the patio']);
      expect(result, isTrue);
      expect(find.text('Add note'), findsNothing);
    });
  });
}
