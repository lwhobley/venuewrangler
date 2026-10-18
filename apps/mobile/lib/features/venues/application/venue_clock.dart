import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../domain/venue_clock.dart';
import 'venues_providers.dart';

export '../domain/venue_clock.dart';

/// The active venue's clock (UTC when no venue is selected, which no time screen reaches).
final venueClockProvider = Provider<VenueClock>((ref) {
  final timezone = ref.watch(activeVenueProvider.select((v) => v?.timezone));
  return VenueClock(timezone ?? 'UTC');
});

/// Shows a snackbar and returns false when the venue's zone is unsupported, so a create/edit
/// action can stop before it saves a time converted with the UTC fallback.
bool ensureSupported(BuildContext context, VenueClock clock) {
  if (clock.isSupported) return true;
  ScaffoldMessenger.of(context).showSnackBar(
    SnackBar(content: Text(unsupportedTimezoneMessage(clock.timezoneId))),
  );
  return false;
}

String unsupportedTimezoneMessage(String timezoneId) =>
    "This venue's time zone ($timezoneId) isn't supported by the app yet, so "
    "times can't be saved here. Ask your administrator to switch the venue to "
    'a supported time zone.';
