import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/auth_repository.dart';
import '../../../core/auth/sign_out_service.dart';
import '../domain/mfa_error.dart';

/// Second step of sign-in: the session passed the password (AAL1) but the account has an
/// authenticator, so the router (app/router.dart) holds the user here until a valid code
/// upgrades the session to AAL2. Leaving the screen is only possible by signing out.
class MfaChallengeScreen extends ConsumerStatefulWidget {
  const MfaChallengeScreen({super.key});

  @override
  ConsumerState<MfaChallengeScreen> createState() => _MfaChallengeScreenState();
}

class _MfaChallengeScreenState extends ConsumerState<MfaChallengeScreen> {
  final _code = TextEditingController();
  bool _busy = false;
  String? _error;
  late final Future<MfaFactor?> _factor = _loadFactor();

  Future<MfaFactor?> _loadFactor() async {
    final factors = await ref.read(mfaRepositoryProvider).listFactors();
    for (final factor in factors) {
      if (factor.verified) return factor;
    }
    return null;
  }

  @override
  void dispose() {
    _code.dispose();
    super.dispose();
  }

  Future<void> _submit(MfaFactor factor) async {
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
      // On success Supabase emits mfaChallengeVerified; the router then leaves this screen.
      await ref
          .read(mfaRepositoryProvider)
          .challenge(factorId: factor.id, code: code);
    } catch (error) {
      if (mounted) setState(() => _error = mfaErrorMessage(error));
      _code.clear();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Two-factor authentication'),
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => signOutAndClearScopedData(
              ProviderScope.containerOf(context, listen: false),
            ),
          ),
        ],
      ),
      body: FutureBuilder<MfaFactor?>(
        future: _factor,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final factor = snapshot.data;
          if (snapshot.hasError || factor == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  'Could not load your authenticator. Sign out and try again.',
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodyLarge,
                ),
              ),
            );
          }
          return Center(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Icon(
                      Icons.shield_outlined,
                      size: 48,
                      color: theme.colorScheme.primary,
                    ),
                    const SizedBox(height: 16),
                    Text(
                      'Enter the 6-digit code from your authenticator app.',
                      textAlign: TextAlign.center,
                      style: theme.textTheme.bodyLarge,
                    ),
                    const SizedBox(height: 16),
                    TextField(
                      controller: _code,
                      autofocus: true,
                      enabled: !_busy,
                      keyboardType: TextInputType.number,
                      maxLength: 6,
                      textAlign: TextAlign.center,
                      autofillHints: const [AutofillHints.oneTimeCode],
                      style: theme.textTheme.headlineSmall,
                      decoration: const InputDecoration(
                        labelText: 'Authenticator code',
                        counterText: '',
                      ),
                      onSubmitted: (_) => _submit(factor),
                    ),
                    if (_error != null) ...[
                      const SizedBox(height: 12),
                      Text(
                        _error!,
                        textAlign: TextAlign.center,
                        style: TextStyle(color: theme.colorScheme.error),
                      ),
                    ],
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: _busy ? null : () => _submit(factor),
                      child: _busy
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Verify'),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}
