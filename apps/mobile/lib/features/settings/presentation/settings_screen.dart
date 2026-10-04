import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/sign_out_service.dart';
import '../../../core/network/supabase_providers.dart';
import '../application/settings_providers.dart';

/// Profile, account, and app settings. Deliberately minimal for this first slice — just the
/// display name every other screen already shows (roster tiles, "created by", etc.) and sign
/// out; organization/venue-level settings are a reasonable follow-up once there's more to
/// configure there.
class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(myProfileProvider);
    final email = ref.watch(supabaseClientProvider).auth.currentUser?.email;

    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => const Center(child: Text('Could not load your profile.')),
        data: (profile) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (email != null) ...[
              Text('Email', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(email),
              const SizedBox(height: 24),
            ],
            FilledButton.icon(
              onPressed: () => _editDisplayName(context, ref, profile.displayName),
              icon: const Icon(Icons.edit_outlined),
              label: Text(profile.displayName == null
                  ? 'Set display name'
                  : 'Display name: ${profile.displayName}'),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => signOutAndClearScopedData(ref),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _editDisplayName(
    BuildContext context,
    WidgetRef ref,
    String? currentName,
  ) async {
    final controller = TextEditingController(text: currentName);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Display name'),
        content: TextField(controller: controller, autofocus: true),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (confirmed != true || controller.text.trim().isEmpty || !context.mounted) return;

    try {
      final userId = ref.read(supabaseClientProvider).auth.currentUser!.id;
      await ref.read(settingsRepositoryProvider).updateDisplayName(userId, controller.text.trim());
      ref.invalidate(myProfileProvider);
    } on PostgrestException catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Something went wrong. Please try again.')),
      );
    }
  }
}
