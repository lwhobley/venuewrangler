import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/sign_out_service.dart';
import '../../../core/network/supabase_providers.dart';
import '../application/settings_providers.dart';
import '../../../core/theme/theme_mode_provider.dart';
import '../../../core/auth/auth_providers.dart';
import '../../ai/presentation/org_ai_toggle_tile.dart';
import '../../invites/presentation/pending_invites_entry.dart';
import '../../mfa/presentation/mfa_enrollment_banner.dart';
import '../../team/domain/team_member.dart';
import '../../venues/application/venues_providers.dart';
import '../../workforce/presentation/employee_profile_widgets.dart';
import '../../workforce/domain/employee_hr_profile.dart';
import '../domain/legal_links.dart';
import 'delete_account_button.dart';

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
    final venue = ref.watch(activeVenueProvider);
    final userId = ref.watch(currentUserIdProvider);
    final role = ref.watch(myVenueRoleProvider).valueOrNull;

    return Scaffold(
      appBar: AppBar(
        title: const Text('Settings'),
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            const Center(child: Text('Could not load your profile.')),
        data: (profile) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (venue != null && userId != null) ...[
              Center(
                child: StaffAvatar(
                  profileKey: (venueId: venue.id, userId: userId),
                  name: profile.displayName ?? 'You',
                  radius: 40,
                ),
              ),
              const SizedBox(height: 12),
              ProfilePhotoButton(
                profileKey: (venueId: venue.id, userId: userId),
                organizationId: venue.organizationId,
              ),
              const SizedBox(height: 16),
              EmployeeHrCard(
                profileKey: (venueId: venue.id, userId: userId),
                name: profile.displayName ?? 'My profile',
                manageEmployment:
                    canManageEmployeeDetails(role, role ?? 'staff'),
              ),
              const SizedBox(height: 24),
            ],
            if (email != null) ...[
              Text('Email', style: Theme.of(context).textTheme.labelMedium),
              const SizedBox(height: 4),
              Text(email),
              const SizedBox(height: 24),
            ],
            const MfaEnrollmentBanner(),
            const PendingInvitesSettingsTile(),
            if (teamManagerRoles.contains(role))
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Team'),
                subtitle: const Text('Roles, access and ownership'),
                trailing: const Icon(Icons.chevron_right),
                onTap: () => context.push('/team'),
              ),
            ListTile(
              leading: const Icon(Icons.extension_outlined),
              title: const Text('Integrations'),
              subtitle: const Text('POS and connected services'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/integrations'),
            ),
            ListTile(
              leading: const Icon(Icons.shield_outlined),
              title: const Text('Two-factor authentication'),
              subtitle: const Text('Require a code from an authenticator app'),
              trailing: const Icon(Icons.chevron_right),
              onTap: () => context.push('/mfa'),
            ),
            if (venue != null &&
                (role == 'organization_owner' || role == 'organization_admin'))
              OrgAiToggleTile(organizationId: venue.organizationId),
            ListTile(
              leading: const Icon(Icons.privacy_tip_outlined),
              title: const Text('Privacy policy'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => openLegalLink(context, privacyPolicyUri),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('Terms of service'),
              trailing: const Icon(Icons.open_in_new),
              onTap: () => openLegalLink(context, termsUri),
            ),
            const SizedBox(height: 16),
            Text('Appearance', style: Theme.of(context).textTheme.labelMedium),
            const SizedBox(height: 8),
            SegmentedButton<ThemeMode>(
              segments: const [
                ButtonSegment(
                  value: ThemeMode.light,
                  icon: Icon(Icons.light_mode_outlined),
                  label: Text('Light'),
                ),
                ButtonSegment(
                  value: ThemeMode.dark,
                  icon: Icon(Icons.dark_mode_outlined),
                  label: Text('Dark'),
                ),
                ButtonSegment(
                  value: ThemeMode.system,
                  icon: Icon(Icons.brightness_auto_outlined),
                  label: Text('Auto'),
                ),
              ],
              selected: {ref.watch(themeModeProvider)},
              onSelectionChanged: (s) =>
                  ref.read(themeModeProvider.notifier).set(s.first),
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () =>
                  _editDisplayName(context, ref, profile.displayName),
              icon: const Icon(Icons.edit_outlined),
              label: Text(
                profile.displayName == null
                    ? 'Set display name'
                    : 'Display name: ${profile.displayName}',
              ),
            ),
            const SizedBox(height: 24),
            OutlinedButton.icon(
              onPressed: () => signOutAndClearScopedData(
                ProviderScope.containerOf(context, listen: false),
              ),
              icon: const Icon(Icons.logout),
              label: const Text('Sign out'),
            ),
            const SizedBox(height: 32),
            const DeleteAccountButton(),
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

    if (confirmed != true ||
        controller.text.trim().isEmpty ||
        !context.mounted) {
      return;
    }

    try {
      final userId = ref.read(supabaseClientProvider).auth.currentUser!.id;
      await ref
          .read(settingsRepositoryProvider)
          .updateDisplayName(userId, controller.text.trim());
      ref.invalidate(myProfileProvider);
    } on PostgrestException catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Something went wrong. Please try again.'),
        ),
      );
    }
  }
}
