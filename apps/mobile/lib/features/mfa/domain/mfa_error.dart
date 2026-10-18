import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/transport_failure.dart';

/// Friendly message for a failed MFA call (enroll, verify, challenge, unenroll).
String mfaErrorMessage(Object error) {
  if (error is AuthException) {
    final text = '${error.message} ${error.code}'.toLowerCase();
    if (text.contains('invalid') && text.contains('code') ||
        text.contains('mfa_verification_failed') ||
        text.contains('invalid totp')) {
      return "That code isn't correct or has expired. Try the latest one.";
    }
    if (text.contains('aal2') || text.contains('assurance')) {
      return 'Confirm with your authenticator first, then try again.';
    }
    if (text.contains('rate') || text.contains('too many')) {
      return 'Too many attempts. Wait a minute and try again.';
    }
    if (text.contains('mfa_factor_name_conflict') ||
        text.contains('already exists')) {
      return 'An authenticator is already being set up. Try again.';
    }
  }
  if (isTransportFailure(error) || error is AuthRetryableFetchException) {
    return 'Could not reach the server. Check your connection.';
  }
  return 'Something went wrong. Please try again.';
}
