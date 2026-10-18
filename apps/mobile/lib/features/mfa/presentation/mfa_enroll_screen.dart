import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/auth_repository.dart';
import '../application/mfa_providers.dart';
import '../domain/mfa_error.dart';

/// Adds an authenticator app: shows the setup key to type (or copy) into the app, then
/// activates the factor with the first code it produces. Pops `true` once activated.
///
/// Supabase also returns the QR code as an SVG, but no SVG renderer is a dependency, so the
/// key (and the otpauth link, which many apps open directly) is shown instead.
class MfaEnrollScreen extends ConsumerStatefulWidget {
  const MfaEnrollScreen({super.key});

  @override
  ConsumerState<MfaEnrollScreen> createState() => _MfaEnrollScreenState();
}

class _MfaEnrollScreenState extends ConsumerState<MfaEnrollScreen> {
  final _code = TextEditingController();
  late final Future<MfaEnrollment> _enrollment =
      ref.read(mfaRepositoryProvider).enrollTotp(issuer: 'Venue Wrangler');
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _copy(String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied')));
  }

  Future<void> _verify(MfaEnrollment enrollment) async {
    final code = _code.text.trim();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-digit code from your app.');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref
          .read(mfaRepositoryProvider)
          .verifyEnrollment(factorId: enrollment.factorId, code: code);
      ref.invalidate(mfaFactorsProvider);
      if (mounted) Navigator.of(context).pop(true);
    } catch (error) {
      if (mounted) setState(() => _error = mfaErrorMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Set up authenticator')),
      body: FutureBuilder<MfaEnrollment>(
        future: _enrollment,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final enrollment = snapshot.data;
          if (enrollment == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  mfaErrorMessage(snapshot.error ?? 'unknown'),
                  textAlign: TextAlign.center,
                ),
              ),
            );
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                '1. In an authenticator app (Google Authenticator, 1Password, '
                'Authy...), add an account using this setup key.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Setup key', style: theme.textTheme.labelMedium),
                      const SizedBox(height: 4),
                      SelectableText(
                        enrollment.secret,
                        style: theme.textTheme.titleMedium
                            ?.copyWith(fontFamily: 'monospace'),
                      ),
                      const SizedBox(height: 8),
                      Wrap(
                        spacing: 8,
                        children: [
                          OutlinedButton.icon(
                            onPressed: () =>
                                _copy('Setup key', enrollment.secret),
                            icon: const Icon(Icons.copy, size: 18),
                            label: const Text('Copy key'),
                          ),
                          OutlinedButton.icon(
                            onPressed: () =>
                                _copy('Setup link', enrollment.uri),
                            icon: const Icon(Icons.link, size: 18),
                            label: const Text('Copy link'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                '2. Enter the 6-digit code the app shows to finish.',
                style: theme.textTheme.bodyMedium,
              ),
              const SizedBox(height: 8),
              TextField(
                controller: _code,
                enabled: !_busy,
                keyboardType: TextInputType.number,
                maxLength: 6,
                decoration: const InputDecoration(
                  labelText: 'Authenticator code',
                  counterText: '',
                ),
                onSubmitted: (_) => _verify(enrollment),
              ),
              if (_error != null) ...[
                const SizedBox(height: 8),
                Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
              ],
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _busy ? null : () => _verify(enrollment),
                child: _busy
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Turn on two-factor authentication'),
              ),
            ],
          );
        },
      ),
    );
  }
}
