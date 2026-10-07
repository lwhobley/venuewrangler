import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/crm/application/crm_providers.dart';
import 'package:venuewrangler_mobile/features/crm/data/crm_repository.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_beo.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_beo_charge.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_contract.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_lead.dart';
import 'package:venuewrangler_mobile/features/crm/presentation/crm_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeCrmRepository implements CrmRepository {
  _FakeCrmRepository({List<CrmBeo>? beos, List<CrmBeoCharge>? charges})
      : _beos = beos ?? [],
        _charges = charges ?? [];

  final List<CrmBeo> _beos;
  final List<CrmBeoCharge> _charges;

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
  }) =>
      throw UnimplementedError();

  @override
  Future<void> updateLeadStatus({
    required String leadId,
    required String status,
  }) =>
      throw UnimplementedError();

  @override
  Future<List<CrmNote>> getNotes({required String leadId}) async => [];

  @override
  Future<void> addNote({required String leadId, required String text}) =>
      throw UnimplementedError();

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
  }) =>
      throw UnimplementedError();

  @override
  Future<void> updateBeoStatus({
    required String beoId,
    required String status,
  }) =>
      throw UnimplementedError();

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

  @override
  Future<List<CrmContract>> getContracts({
    required String venueId,
    int limit = 100,
  }) async =>
      [];

  @override
  Future<void> updateContractStatus({
    required String contractId,
    required String status,
  }) =>
      throw UnimplementedError();

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
}
