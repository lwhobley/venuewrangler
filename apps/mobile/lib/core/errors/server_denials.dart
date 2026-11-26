import 'package:supabase_flutter/supabase_flutter.dart';

import 'app_error.dart';

/// Error code the server uses when a sensitive operation needs an authenticator-verified
/// (AAL2) session: Edge Functions answer 403 `{error: 'mfa_required'}`, Postgres raises 42501
/// with this message.
const mfaRequiredCode = 'mfa_required';

/// Shown when [mfaRequiredCode] comes back and the person can verify with an authenticator.
const mfaRequiredMessage = 'Verify with your authenticator to continue.';

/// Shown when [mfaRequiredCode] comes back but the account has no authenticator yet.
const mfaEnrolmentRequiredMessage =
    'This needs two-factor authentication. Set up an authenticator app in '
    'Settings > Two-factor authentication, then try again.';

/// 503 from an MFA-gated Edge Function when it could not check the session's assurance level.
/// Not a refusal: the person should simply try again.
const mfaCheckUnavailableCode = 'mfa_check_unavailable';

const mfaCheckUnavailableMessage =
    "Couldn't verify your sign-in security right now. Try again.";

/// Text of the 42501 the database raises (trigger `app_hidden.require_clock_in_location`,
/// migration 20261023101510_launch_review_workflows.sql) when a punch is made at a venue with
/// no usable latitude/longitude: "Venue location is not configured. Ask a manager to set it in
/// Settings before clocking in."
const venueLocationNotConfiguredText = 'Venue location is not configured';

/// The same refusal as an error code, accepted too in case the server ever sends one.
const venueGeofenceRequiredCode = 'venue_geofence_required';

const venueGeofenceRequiredMessage =
    "This venue's location isn't set up yet. Ask a manager to set it in venue "
    'settings.';

/// True when [error] is the server's step-up refusal, however it arrived: an already-mapped
/// [MfaRequiredError], a Postgres 42501 `mfa_required`, or an Edge Function error body.
bool isMfaRequired(Object error) =>
    error is MfaRequiredError || _carriesCode(error, mfaRequiredCode);

/// True when [error] says the venue has no clock-in location configured yet.
bool isVenueGeofenceRequired(Object error) =>
    _carriesCode(error, venueLocationNotConfiguredText) ||
    _carriesCode(error, venueGeofenceRequiredCode);

bool _carriesCode(Object error, String code) {
  if (error is PostgrestException) {
    return '${error.message} ${error.details} ${error.hint}'.contains(code);
  }
  if (error is FunctionException) {
    final details = error.details;
    if (details is Map) {
      return details['error'] == code ||
          '${details['message'] ?? ''}'.contains(code);
    }
    return '${details ?? ''}'.contains(code);
  }
  return false;
}
