import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/errors/app_error.dart';
import '../application/integrations_providers.dart';
import '../domain/payroll_connection.dart';

/// Landing screen for the `venuewrangler://integrations/connected?provider=&nonce=` deep link the
/// `{provider}-oauth` callback redirects to after the user approves access. The callback has not
/// activated anything yet: this screen redeems the one-time [nonce] with the signed-in session
/// (see [IntegrationsRepository.completeConnection]).
class IntegrationCompleteScreen extends ConsumerStatefulWidget {
  const IntegrationCompleteScreen({
    super.key,
    required this.provider,
    required this.nonce,
  });

  final String? provider;
  final String? nonce;

  @override
  ConsumerState<IntegrationCompleteScreen> createState() =>
      _IntegrationCompleteScreenState();
}

class _IntegrationCompleteScreenState
    extends ConsumerState<IntegrationCompleteScreen> {
  String? _error;
  bool _done = false;

  @override
  void initState() {
    super.initState();
    // Run once, after the first frame, so providers are readable and the router is settled.
    WidgetsBinding.instance.addPostFrameCallback((_) => _complete());
  }

  Future<void> _complete() async {
    final provider = PayrollProvider.tryParse(widget.provider);
    final nonce = widget.nonce;
    if (provider == null || nonce == null || nonce.isEmpty) {
      setState(() => _error = 'This connection link is incomplete.');
      return;
    }

    try {
      await ref
          .read(integrationsRepositoryProvider)
          .completeConnection(provider, nonce);
      ref.invalidate(payrollConnectionsForVenueProvider);
      if (!mounted) return;
      setState(() => _done = true);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${provider.label} connected.')),
      );
      context.go('/integrations');
    } on AppError catch (error) {
      if (mounted) setState(() => _error = error.message);
    } catch (_) {
      if (mounted) {
        setState(
          () => _error = 'Could not finish connecting. Please try again.',
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      appBar: AppBar(title: const Text('Connecting')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: error == null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (!_done) const CircularProgressIndicator(),
                    const SizedBox(height: 16),
                    const Text('Finishing the connection…'),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(error, textAlign: TextAlign.center),
                    const SizedBox(height: 16),
                    FilledButton(
                      onPressed: () => context.go('/integrations'),
                      child: const Text('Back to Integrations'),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}

/// Landing screen for `venuewrangler://integrations/error` (the provider declined or the
/// callback failed). The callback only ever sends a fixed `reason` code, never provider text.
class IntegrationErrorScreen extends StatelessWidget {
  const IntegrationErrorScreen({super.key, this.reason});

  final String? reason;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Connection failed')),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'The connection was not completed. You can try again from Integrations.',
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => context.go('/integrations'),
                child: const Text('Back to Integrations'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
