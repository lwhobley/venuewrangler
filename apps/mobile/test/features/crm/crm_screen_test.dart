import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/crm/application/crm_providers.dart';
import 'package:venuewrangler_mobile/features/crm/data/crm_repository.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_beo.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_contract.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_lead.dart';
import 'package:venuewrangler_mobile/features/crm/presentation/crm_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeCrmRepository implements CrmRepository {
  _FakeCrmRepository({List<CrmBeo>? beos}) : _beos = beos ?? [];

  final List<CrmBeo> _beos;

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
}
