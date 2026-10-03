import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:url_launcher_platform_interface/link.dart';
import 'package:url_launcher_platform_interface/url_launcher_platform_interface.dart';
import 'package:venuewrangler_mobile/features/crm/application/crm_providers.dart';
import 'package:venuewrangler_mobile/features/crm/data/crm_repository.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_beo.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_contract.dart';
import 'package:venuewrangler_mobile/features/crm/domain/crm_lead.dart';
import 'package:venuewrangler_mobile/features/crm/presentation/crm_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

/// Records what url_launcher was asked to open, without actually touching a platform channel
/// (there is none in a widget test) — the standard way to test code that calls the top-level
/// `launchUrl()` function, per url_launcher's own testing docs.
class _FakeUrlLauncher extends UrlLauncherPlatform {
  String? lastLaunchedUrl;

  @override
  LinkDelegate? get linkDelegate => null;

  @override
  Future<bool> canLaunch(String url) async => true;

  @override
  Future<bool> launchUrl(String url, LaunchOptions options) async {
    lastLaunchedUrl = url;
    return true;
  }
}

class _FakeCrmRepository implements CrmRepository {
  _FakeCrmRepository({List<CrmBeo>? beos}) : _beos = beos ?? [];

  final List<CrmBeo> _beos;
  String? lastDepositCheckoutBeoId;
  bool waiveCalled = false;
  Object? depositCheckoutError;

  @override
  Future<List<CrmLead>> getLeads({required String venueId, String? search, int limit = 100}) async => [];

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
  Future<void> updateLeadStatus({required String leadId, required String status}) => throw UnimplementedError();

  @override
  Future<List<CrmNote>> getNotes({required String leadId}) async => [];

  @override
  Future<void> addNote({required String leadId, required String text}) => throw UnimplementedError();

  @override
  Future<List<CrmActivityLogEntry>> getActivity({required String leadId, int limit = 50}) async => [];

  @override
  Future<List<CrmBeo>> getBeos({required String venueId, int limit = 100}) async => _beos;

  @override
  Future<CrmBeo> createBeo({
    required String venueId,
    String? leadId,
    required String eventName,
    DateTime? eventDate,
    int? guestCount,
    String? venueSpace,
    int? depositCents,
  }) =>
      throw UnimplementedError();

  @override
  Future<void> updateBeoStatus({required String beoId, required String status}) => throw UnimplementedError();

  @override
  Future<bool> waiveBeoDeposit({required String beoId}) async {
    waiveCalled = true;
    return true;
  }

  @override
  Future<({String contractId, bool alreadyExisted})> convertBeoToContract({required String beoId}) =>
      throw UnimplementedError();

  @override
  Future<List<CrmContract>> getContracts({required String venueId, int limit = 100}) async => [];

  @override
  Future<void> updateContractStatus({required String contractId, required String status}) =>
      throw UnimplementedError();

  @override
  Future<List<CrmForecastRow>> getForecast({required String venueId}) async => [];

  @override
  Future<List<CrmStaleLead>> getStaleLeads({required String venueId, int days = 5}) async => [];

  @override
  Future<String> createDepositCheckoutUrl({required String beoId}) async {
    lastDepositCheckoutBeoId = beoId;
    if (depositCheckoutError != null) throw depositCheckoutError!;
    return 'https://checkout.stripe.com/c/pay/test_session_123';
  }

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

  CrmBeo depositDueBeo({String status = 'draft'}) => CrmBeo(
        id: 'beo-1',
        venueId: 'venue-1',
        eventName: 'Smith Wedding',
        depositCents: 50000,
        depositStatus: 'due',
        status: status,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );

  late _FakeUrlLauncher fakeLauncher;

  setUp(() {
    fakeLauncher = _FakeUrlLauncher();
    UrlLauncherPlatform.instance = fakeLauncher;
  });

  testWidgets('shows an empty state when the venue has no BEOs', (tester) async {
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

  testWidgets('a BEO with an unpaid deposit shows Collect and Waive actions', (tester) async {
    final fakeRepo = _FakeCrmRepository(beos: [depositDueBeo()]);

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

    // Expand the BEO tile to reveal the deposit-due row.
    await tester.tap(find.text('Smith Wedding'));
    await tester.pumpAndSettle();

    expect(find.text('Deposit due'), findsOneWidget);
    expect(find.text('\$500.00'), findsOneWidget);
    expect(find.text('Collect'), findsOneWidget);
    expect(find.text('Waive'), findsOneWidget);
  });

  testWidgets('tapping Collect creates a Stripe checkout session and opens it', (tester) async {
    final fakeRepo = _FakeCrmRepository(beos: [depositDueBeo()]);

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
    await tester.tap(find.text('Smith Wedding'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Collect'));
    await tester.pumpAndSettle();

    expect(fakeRepo.lastDepositCheckoutBeoId, 'beo-1');
    expect(fakeLauncher.lastLaunchedUrl, 'https://checkout.stripe.com/c/pay/test_session_123');
  });

  testWidgets('a failed checkout creation shows the mapped error instead of crashing', (tester) async {
    final fakeRepo = _FakeCrmRepository(beos: [depositDueBeo()])
      ..depositCheckoutError = Exception('deposit_already_paid');

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
    await tester.tap(find.text('Smith Wedding'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Collect'));
    await tester.pumpAndSettle();

    expect(fakeLauncher.lastLaunchedUrl, isNull);
    expect(find.byType(SnackBar), findsOneWidget);
  });

  testWidgets('tapping Waive calls the repository and refreshes the list', (tester) async {
    final fakeRepo = _FakeCrmRepository(beos: [depositDueBeo()]);

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
    await tester.tap(find.text('Smith Wedding'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Waive'));
    await tester.pumpAndSettle();

    expect(fakeRepo.waiveCalled, isTrue);
  });
}
