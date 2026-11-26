import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../errors/app_error.dart';
import '../errors/server_denials.dart';
import 'auth_providers.dart';
import 'reauth_dialog.dart';

/// Runs [action]; if the server answers `mfa_required`, offers the existing step-up and runs
/// [action] once more when it succeeds.
///
/// - Account with a verified authenticator: [confirmPasswordReauth] (password plus a fresh
///   authenticator code, restoring AAL2), then one retry.
/// - No authenticator yet: a dialog that points to the enrolment screen (`/mfa`).
///
/// When step-up is declined or not possible, throws [MfaRequiredError] with a message the
/// caller can show as-is. A second `mfa_required` after a successful step-up propagates as an
/// [MfaRequiredError] too, so this never loops.
Future<T> runWithMfaStepUp<T>(
  BuildContext context,
  WidgetRef ref,
  Future<T> Function() action,
) async {
  try {
    return await action();
  } catch (error) {
    if (!isMfaRequired(error)) rethrow;
    if (!context.mounted) throw const MfaRequiredError();
    switch (await stepUpForMfa(context, ref)) {
      case MfaStepUpResult.verified:
        break;
      case MfaStepUpResult.declined:
        throw const MfaRequiredError();
      case MfaStepUpResult.needsEnrolment:
        throw const MfaRequiredError(mfaEnrolmentRequiredMessage);
    }
  }
  try {
    return await action();
  } catch (error) {
    if (isMfaRequired(error)) throw const MfaRequiredError();
    rethrow;
  }
}

/// Outcome of [stepUpForMfa].
enum MfaStepUpResult {
  /// Password and authenticator code confirmed: retry the action.
  verified,

  /// The person cancelled, or the session did not return to AAL2.
  declined,

  /// No verified authenticator on the account; the person was offered enrolment.
  needsEnrolment,
}

/// Asks the signed-in person to verify with their authenticator (the existing
/// [confirmPasswordReauth] step-up). Without a verified authenticator it offers the enrolment
/// screen instead.
Future<MfaStepUpResult> stepUpForMfa(
  BuildContext context,
  WidgetRef ref,
) async {
  bool hasAuthenticator;
  try {
    final factors = await ref.read(mfaRepositoryProvider).listFactors();
    hasAuthenticator = factors.any((factor) => factor.verified);
  } catch (_) {
    // Cannot tell: try the step-up; it resolves factors again and the server still decides.
    hasAuthenticator = true;
  }
  if (!context.mounted) return MfaStepUpResult.declined;
  if (hasAuthenticator) {
    final confirmed = await confirmPasswordReauth(
      context,
      ref,
      title: mfaRequiredMessage,
      reason: 'For your security, confirm your password and the current code '
          'from your authenticator app.',
    );
    return confirmed ? MfaStepUpResult.verified : MfaStepUpResult.declined;
  }
  final setUp = await showDialog<bool>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('Two-factor authentication required'),
      content: const Text(
        'This change needs two-factor authentication. Set up an authenticator '
        'app, then try again.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(dialogContext).pop(true),
          child: const Text('Set up'),
        ),
      ],
    ),
  );
  if (setUp == true && context.mounted) {
    // ignore: unawaited_futures
    context.push('/mfa');
  }
  return MfaStepUpResult.needsEnrolment;
}
