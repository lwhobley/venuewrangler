import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dart:io' show Platform;

import '../../../core/location/location_service.dart';
import '../../../core/network/supabase_providers.dart';
import '../../../core/security/app_attest_providers.dart';
import '../../../core/security/play_integrity_service.dart';
import '../data/attested_punch_client.dart';
import '../data/time_clock_repository.dart';
import '../domain/time_entry.dart';

final playIntegrityServiceProvider =
    Provider<PlayIntegrityService>((ref) => PlayIntegrityService());

/// Device proof for punches: App Attest on iOS, Play Integrity on Android, none elsewhere.
final punchProofProviderProvider = Provider<PunchProofProvider>((ref) {
  final appAttest = ref.watch(appAttestServiceProvider);
  final playIntegrity = ref.watch(playIntegrityServiceProvider);
  return PlatformPunchProofProvider(
    iosAssertion: appAttest.generateAssertion,
    androidToken: playIntegrity.requestToken,
    platform: () => kIsWeb
        ? 'web'
        : Platform.isIOS
            ? 'ios'
            : Platform.isAndroid
                ? 'android'
                : 'other',
  );
});

final timeClockRepositoryProvider = Provider<TimeClockRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseTimeClockRepository(
    client,
    attestedPunches: AttestedPunchClient.forClient(
      client,
      proof: ref.watch(punchProofProviderProvider),
    ),
  );
});

final locationServiceProvider =
    Provider<LocationService>((ref) => const GeolocatorLocationService());

/// Whether this build may create punches. Punches carry a client-reported GPS fix, which a
/// browser cannot vouch for (DevTools can spoof it and `isMocked` is always false there), so
/// clock in/out and breaks are mobile-only; history and the clock board stay readable on web.
final timeClockPunchSupportedProvider = Provider<bool>((ref) => !kIsWeb);

final activeTimeEntryProvider =
    FutureProvider.autoDispose.family<TimeEntry?, String>((ref, venueId) {
  return ref
      .watch(timeClockRepositoryProvider)
      .getActiveEntry(venueId: venueId);
});

/// The user's open entry when it is at a different venue than [venueId] (null otherwise).
final openElsewhereTimeEntryProvider =
    FutureProvider.autoDispose.family<TimeEntry?, String>((ref, venueId) {
  return ref
      .watch(timeClockRepositoryProvider)
      .getOpenEntryElsewhere(venueId: venueId);
});

final myTimeEntriesProvider =
    FutureProvider.autoDispose.family<List<TimeEntry>, String>((ref, venueId) {
  return ref.watch(timeClockRepositoryProvider).getMyEntries(venueId: venueId);
});
