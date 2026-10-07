import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/sign_out_service.dart';
import '../application/settings_providers.dart';

/// "Delete account" — personal self-deletion only (not organization/tenant offboarding; see
/// `public.request_account_deletion`'s migration header comment). A standalone widget rather
/// than inline in [SettingsScreen] so it depends only on [settingsRepositoryProvider] and
/// [signOutAndClearScopedData] — not `supabaseClientProvider`/`myProfileProvider`, which
/// SettingsScreen reads directly and which widget tests can't easily fake — keeping this
/// independently testable.
class DeleteAccountButton extends ConsumerWidget {
  const DeleteAccountButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return TextButton.icon(
      onPressed: () => _deleteAccount(context, ref),
      icon: Icon(
        Icons.delete_forever_outlined,
        color: Theme.of(context).colorScheme.error,
      ),
      label: Text(
        'Delete account',
        style: TextStyle(color: Theme.of(context).colorScheme.error),
      ),
    );
  }

  Future<void> _deleteAccount(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete your account?'),
        content: const Text(
          'This permanently removes your profile, photo and venue memberships, and signs '
          'you out everywhere. This cannot be undone.\n\n'
          "If you're the only owner of an organization, add another owner first — this "
          "won't let you delete an account that would leave one without one.",
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
              foregroundColor: Theme.of(context).colorScheme.onError,
            ),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete account'),
          ),
        ],
      ),
    );

    if (confirmed != true || !context.mounted) return;

    try {
      await ref.read(settingsRepositoryProvider).deleteAccount();
      if (!context.mounted) return;
      await signOutAndClearScopedData(ref);
    } on PostgrestException catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(e.message)),
      );
    }
  }
}
