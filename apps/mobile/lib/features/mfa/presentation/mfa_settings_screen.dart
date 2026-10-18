import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/auth_repository.dart';
import '../../../core/widgets/state_views.dart';
import '../application/mfa_providers.dart';
import '../domain/mfa_error.dart';
import 'mfa_enroll_screen.dart';

/// Lists the account's authenticators, adds a new one, and removes one.
class MfaSettingsScreen extends ConsumerWidget {
  const MfaSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final factorsAsync = ref.watch(mfaFactorsProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Two-factor authentication')),
      body: factorsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          message: mfaErrorMessage(error),
          onRetry: () => ref.invalidate(mfaFactorsProvider),
        ),
        data: (factors) {
          final verified = factors.where((f) => f.verified).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                verified.isEmpty
                    ? 'Add an authenticator app so a stolen password alone cannot '
                        'open your account. You will enter a code each time you sign in.'
                    : 'Two-factor authentication is on. Signing in asks for a code '
                        'from your authenticator app.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 16),
              for (final factor in verified)
                Card(
                  child: ListTile(
                    leading: const Icon(Icons.phonelink_lock_outlined),
                    title: const Text('Authenticator app'),
                    subtitle: factor.createdAt == null
                        ? null
                        : Text('Added ${_date(factor.createdAt!)}'),
                    trailing: IconButton(
                      icon: const Icon(Icons.delete_outline),
                      tooltip: 'Remove authenticator',
                      onPressed: () => _remove(context, ref, factor),
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: () => _enroll(context, ref),
                icon: const Icon(Icons.add),
                label: Text(
                  verified.isEmpty
                      ? 'Set up authenticator app'
                      : 'Add another authenticator',
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  String _date(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';

  Future<void> _enroll(BuildContext context, WidgetRef ref) async {
    final done = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const MfaEnrollScreen()),
    );
    if (done == true && context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Two-factor authentication is on.')),
      );
    }
    ref.invalidate(mfaFactorsProvider);
  }

  Future<void> _remove(
    BuildContext context,
    WidgetRef ref,
    MfaFactor factor,
  ) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Remove authenticator?'),
        content: const Text(
          'Your account will be protected by your password alone until you add '
          'another authenticator.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(mfaRepositoryProvider);
    try {
      await repository.unenroll(factor.id);
      messenger.showSnackBar(
        const SnackBar(content: Text('Authenticator removed.')),
      );
    } catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(mfaErrorMessage(error))));
    }
    ref.invalidate(mfaFactorsProvider);
  }
}
