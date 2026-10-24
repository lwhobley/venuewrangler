import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/location/location_service.dart';
import 'package:venuewrangler_mobile/features/time_clock/application/time_clock_providers.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/data/venues_repository.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue_location.dart';
import 'package:venuewrangler_mobile/features/venues/presentation/venue_location_prompt.dart';
import 'package:venuewrangler_mobile/features/venues/presentation/venue_location_screen.dart';

final _venue = Venue(
  id: 'v1',
  organizationId: 'o1',
  name: 'Marigold Supper Club',
  timezone: 'America/Chicago',
  createdAt: DateTime(2026),
);

class _FakeVenuesRepository implements VenuesRepository {
  ({double lat, double lng, int radius, String? address})? saved;

  @override
  Future<List<Venue>> fetchVenuesForOrganization(String organizationId) async =>
      [];

  @override
  Future<Venue> setVenueLocation({
    required String venueId,
    required double latitude,
    required double longitude,
    required int geofenceRadiusM,
    String? address,
  }) async {
    saved = (
      lat: latitude,
      lng: longitude,
      radius: geofenceRadiusM,
      address: address,
    );
    return Venue(
      id: venueId,
      organizationId: _venue.organizationId,
      name: _venue.name,
      timezone: _venue.timezone,
      latitude: latitude,
      longitude: longitude,
      geofenceRadiusM: geofenceRadiusM,
      address: address,
      createdAt: _venue.createdAt,
    );
  }
}

class _FakeLocation implements LocationService {
  @override
  Future<LocationFix> currentFix() async => const LocationFix(
        lat: 41.878113,
        lng: -87.629799,
        accuracyM: 12,
        mocked: false,
      );
}

void main() {
  test('parseCoordinates accepts map-app text and rejects junk', () {
    expect(
      parseCoordinates(' 41.8781, -87.6298 '),
      (latitude: 41.8781, longitude: -87.6298),
    );
    expect(parseCoordinates('41.8781 -87.6298'), isNotNull);
    expect(parseCoordinates('41.8781'), isNull);
    expect(parseCoordinates('91, 10'), isNull);
    expect(parseCoordinates('0, 0'), isNull);
    expect(parseCoordinates('abc, def'), isNull);
  });

  test('a venue at (0, 0) or without coordinates has no location', () {
    expect(_venue.hasLocation, isFalse);
    expect(
      Venue.fromJson({
        'id': 'v',
        'organization_id': 'o',
        'name': 'n',
        'latitude': 0,
        'longitude': 0,
        'created_at': '2026-01-01T00:00:00Z',
      }).hasLocation,
      isFalse,
    );
    final located = Venue.fromJson({
      'id': 'v',
      'organization_id': 'o',
      'name': 'n',
      'latitude': 41.8,
      'longitude': -87.6,
      'geofence_radius_m': 150,
      'address': '1 Main St',
      'created_at': '2026-01-01T00:00:00Z',
    });
    expect(located.hasLocation, isTrue);
    expect(located.geofenceRadiusM, 150);
    expect(located.address, '1 Main St');
  });

  testWidgets('the prompt shows only to managers of a venue with no location',
      (tester) async {
    Future<void> pump(Venue venue, String role) async {
      await tester.pumpWidget(
        ProviderScope(
          // A new scope per case: a ProviderScope keeps its first overrides.
          key: ValueKey(role),
          overrides: [
            activeVenueProvider.overrideWith((ref) => venue),
            myVenueRoleProvider.overrideWith((ref) async => role),
          ],
          child: const MaterialApp(home: Scaffold(body: VenueLocationPrompt())),
        ),
      );
      await tester.pumpAndSettle();
    }

    await pump(_venue, 'venue_manager');
    expect(find.text("Set your venue's location"), findsOneWidget);

    await pump(_venue, 'staff');
    expect(find.text("Set your venue's location"), findsNothing);
  });

  testWidgets('a manager sets the location from their current position',
      (tester) async {
    final repo = _FakeVenuesRepository();
    final container = ProviderContainer(
      overrides: [
        activeVenueProvider.overrideWith((ref) => _venue),
        venuesRepositoryProvider.overrideWithValue(repo),
        locationServiceProvider.overrideWithValue(_FakeLocation()),
      ],
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: const MaterialApp(home: VenueLocationScreen()),
      ),
    );
    await tester.pumpAndSettle();

    // Saving without a position is refused in the form.
    await tester.tap(find.text('Save location'));
    await tester.pumpAndSettle();
    expect(repo.saved, isNull);
    expect(
      find.textContaining('Enter a latitude and longitude'),
      findsOneWidget,
    );

    await tester.enterText(
      find.widgetWithText(TextFormField, 'Address'),
      '123 W Marigold St, Chicago',
    );
    await tester.tap(find.text('Use my current location'));
    await tester.pumpAndSettle();
    expect(find.text('41.878113, -87.629799'), findsOneWidget);
    expect(find.textContaining('Accurate to about 12 m'), findsOneWidget);

    await tester.tap(find.text('Save location'));
    await tester.pumpAndSettle();

    expect(repo.saved?.lat, 41.878113);
    expect(repo.saved?.lng, -87.629799);
    expect(repo.saved?.radius, 100);
    expect(repo.saved?.address, '123 W Marigold St, Chicago');
    // The active venue now carries the location, so the prompt goes away.
    expect(container.read(activeVenueProvider)?.hasLocation, isTrue);
  });
}
