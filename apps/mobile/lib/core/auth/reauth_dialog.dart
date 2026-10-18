import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'auth_providers.dart';
import 'auth_repository.dart';

/// Step-up for destructive or credential-changing actions (delete account, change password):
/// asks the signed-in person to re-enter their current password before the action runs.
///
/// Returns `true` when the action may proceed: the password was confirmed, or the account has
/// no password to confirm (OAuth-only sign-in, or no email on file), in which case the dialog
/// is skipped. Returns `false` if the person cancels.
///
/// Confirming signs in again with the same email, which issues a fresh session at AAL1. When
/// the account has a verified authenticator the dialog therefore also asks for a code and
/// answers the challenge so the session returns to AAL2 (otherwise the router would send the
/// person to the MFA challenge screen mid-action).
Future<bool> confirmPasswordReauth(
  BuildContext context,
  WidgetRef ref, {
  String title = 'Confirm your password',
  String reason = 'Enter your current password to continue.',
}) async {
  final user = ref.read(authRepositoryProvider).currentSession?.user;
  final email = user?.email;
  if (user == null || email == null || email.isEmpty || !_hasPassword(user)) {
    return true;
  }
  final totpFactorId = _verifiedTotpFactorId(user);
  final confirmed = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (_) => ReauthDialog(
      email: email,
      title: title,
      reason: reason,
      totpFactorId: totpFactorId,
      authRepository: ref.read(authRepositoryProvider),
      mfaRepository: ref.read(mfaRepositoryProvider),
    ),
  );
  return confirmed ?? false;
}

/// `app_metadata.providers` lists how the account can sign in; accounts created through an
/// identity provider only have no password to re-enter. Missing metadata counts as a password
/// account, the safer assumption.
bool _hasPassword(User user) {
  final providers = user.appMetadata['providers'];
  if (providers is List && providers.isNotEmpty) {
    return providers.contains('email');
  }
  final provider = user.appMetadata['provider'];
  return provider == null || provider == 'email';
}

String? _verifiedTotpFactorId(User user) {
  for (final factor in user.factors ?? const <Factor>[]) {
    if (factor.factorType == FactorType.totp &&
        factor.status == FactorStatus.verified) {
      return factor.id;
    }
  }
  return null;
}

@visibleForTesting
class ReauthDialog extends StatefulWidget {
  const ReauthDialog({
    super.key,
    required this.email,
    required this.title,
    required this.reason,
    required this.totpFactorId,
    required this.authRepository,
    required this.mfaRepository,
  });

  final String email;
  final String title;
  final String reason;

  /// Set when the account has a verified authenticator that must be re-answered.
  final String? totpFactorId;
  final AuthRepository authRepository;
  final MfaRepository mfaRepository;

  @override
  State<ReauthDialog> createState() => _ReauthDialogState();
}

class _ReauthDialogState extends State<ReauthDialog> {
  final _password = TextEditingController();
  final _code = TextEditingController();
  bool _busy = false;
  bool _passwordConfirmed = false;
  String? _error;

  @override
  void dispose() {
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final needsCode = widget.totpFactorId != null;
    if (_password.text.isEmpty || (needsCode && _code.text.trim().isEmpty)) {
      setState(() => _error = 'Fill in every field.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (!_passwordConfirmed) {
        await widget.authRepository.signInWithPassword(
          email: widget.email,
          password: _password.text,
        );
        _passwordConfirmed = true;
      }
    } on AuthRetryableFetchException {
      _fail('Could not confirm your password. Check your connection.');
      return;
    } on AuthException {
      _fail("That password isn't correct.");
      return;
    } catch (_) {
      _fail('Could not confirm your password. Check your connection.');
      return;
    }
    if (needsCode) {
      try {
        await widget.mfaRepository.challenge(
          factorId: widget.totpFactorId!,
          code: _code.text.trim(),
        );
      } on AuthRetryableFetchException {
        _fail('Could not confirm your code. Check your connection.');
        return;
      } on AuthException {
        _fail("That code isn't correct.");
        return;
      } catch (_) {
        _fail('Could not confirm your code. Check your connection.');
        return;
      }
    }
    if (mounted) Navigator.of(context).pop(true);
  }

  void _fail(String message) {
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.reason),
            const SizedBox(height: 12),
            TextField(
              controller: _password,
              obscureText: true,
              enabled: !_busy && !_passwordConfirmed,
              autofocus: true,
              autofillHints: const [AutofillHints.password],
              decoration: const InputDecoration(labelText: 'Current password'),
              onSubmitted: (_) =>
                  widget.totpFactorId == null ? _submit() : null,
            ),
            if (widget.totpFactorId != null) ...[
              const SizedBox(height: 12),
              TextField(
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Authenticator code',
                  counterText: '',
                ),
                onSubmitted: (_) => _submit(),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(
                _error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Confirm'),
        ),
      ],
    );
  }
}
