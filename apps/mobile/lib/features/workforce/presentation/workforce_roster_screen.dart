import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../../ai/application/ai_providers.dart';
import '../../ai/domain/ai_models.dart';
import '../../venues/application/venues_providers.dart';
import '../application/workforce_providers.dart';
import '../domain/workforce_models.dart';

/// Staff roster + invites for the active venue. The roster list is read-only here (members
/// are managed via `memberships`, not from this screen); invites are the only write path,
/// per workforce_invites.sql's "redemption is a future Edge Function" scope note — accepting
/// an invite into an actual membership is not implemented yet, by design.
class WorkforceRosterScreen extends ConsumerWidget {
  const WorkforceRosterScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final rosterAsync = ref.watch(rosterForVenueProvider(venue.id));
    final invitesAsync = ref.watch(invitesForVenueProvider(venue.id));

    return Scaffold(
      appBar: AppBar(title: Text('Staff — ${venue.name}')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(rosterForVenueProvider(venue.id));
          ref.invalidate(invitesForVenueProvider(venue.id));
        },
        child: ListView(
          children: [
            const _SectionHeader('Roster'),
            rosterAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const ListTile(title: Text('Could not load roster.')),
              data: (roster) => roster.isEmpty
                  ? const ListTile(title: Text('No roster members yet.'))
                  : Column(
                      children: [
                        for (final member in roster)
                          ListTile(
                            leading: const Icon(Icons.person_outline),
                            title: Text(member.displayName ?? '(no name set)'),
                            subtitle: Text(member.role),
                          ),
                      ],
                    ),
            ),
            const Divider(),
            const _SectionHeader('Pending invites'),
            invitesAsync.when(
              loading: () => const Padding(
                padding: EdgeInsets.all(16),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (_, __) => const ListTile(title: Text('Could not load invites.')),
              data: (invites) {
                final pending =
                    invites.where((invite) => invite.status == InviteStatus.pending).toList();
                if (pending.isEmpty) {
                  return const ListTile(title: Text('No pending invites.'));
                }
                return Column(
                  children: [
                    for (final invite in pending)
                      ListTile(
                        leading: const Icon(Icons.mail_outline),
                        title: Text(invite.email),
                        subtitle: Text(invite.role.label),
                        trailing: TextButton(
                          onPressed: () => _revokeInvite(context, ref, invite.id, venue.id),
                          child: const Text('Revoke'),
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
      floatingActionButton: Column(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          FloatingActionButton.extended(
            heroTag: 'import-staff',
            onPressed: () => _showImportDialog(context, ref, venue.id),
            icon: const Icon(Icons.auto_awesome_outlined),
            label: const Text('Import from paste'),
          ),
          const SizedBox(height: 12),
          FloatingActionButton.extended(
            heroTag: 'invite-staff',
            onPressed: () => _showInviteDialog(context, ref, venue.id),
            icon: const Icon(Icons.person_add_alt_outlined),
            label: const Text('Invite staff'),
          ),
        ],
      ),
    );
  }

  Future<void> _showInviteDialog(BuildContext context, WidgetRef ref, String venueId,
      {String? prefillEmail}) async {
    final emailController = TextEditingController(text: prefillEmail);
    var role = WorkforceRole.staff;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Invite staff'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: emailController,
                autofocus: prefillEmail == null,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Email'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<WorkforceRole>(
                value: role,
                decoration: const InputDecoration(labelText: 'Role'),
                items: [
                  for (final value in WorkforceRole.values)
                    DropdownMenuItem(value: value, child: Text(value.label)),
                ],
                onChanged: (value) => setState(() => role = value ?? role),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Invite'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || emailController.text.trim().isEmpty || !context.mounted) return;

    try {
      await ref.read(workforceRepositoryProvider).createInvite(
            venueId: venueId,
            email: emailController.text.trim(),
            role: role,
          );
      ref.invalidate(invitesForVenueProvider(venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = switch (error.code) {
        '42501' => "You don't have permission to invite staff here.",
        '23505' => 'There is already a pending invite for that email.',
        _ => 'Something went wrong. Please try again.',
      };
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _revokeInvite(
    BuildContext context,
    WidgetRef ref,
    String inviteId,
    String venueId,
  ) async {
    try {
      await ref.read(workforceRepositoryProvider).revokeInvite(inviteId);
      ref.invalidate(invitesForVenueProvider(venueId));
    } on PostgrestException catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("You don't have permission to revoke this invite.")),
      );
    }
  }

  Future<void> _showImportDialog(BuildContext context, WidgetRef ref, String venueId) async {
    final textController = TextEditingController();

    final pastedText = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Paste a staff list'),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLines: 8,
          decoration: const InputDecoration(
            hintText: 'Paste names/emails/phones copied from a spreadsheet or email…',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(textController.text.trim()),
            child: const Text('Parse'),
          ),
        ],
      ),
    );

    if (pastedText == null || pastedText.isEmpty || !context.mounted) return;

    StaffImportResult result;
    try {
      result = await ref
          .read(aiRepositoryProvider)
          .parseStaffImport(venueId: venueId, pastedText: pastedText);
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }

    if (!context.mounted) return;
    if (result.staff.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Nothing could be parsed from that text.')),
      );
      return;
    }

    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Review parsed staff'),
        content: SizedBox(
          width: double.maxFinite,
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final row in result.staff)
                ListTile(
                  title: Text(row.fullName),
                  subtitle: Text([
                    if (row.email != null) row.email!,
                    if (row.roleHint != null) row.roleHint!,
                  ].join(' · ')),
                  trailing: row.email == null
                      ? null
                      : TextButton(
                          onPressed: () {
                            Navigator.of(context).pop();
                            _showInviteDialog(context, ref, venueId, prefillEmail: row.email);
                          },
                          child: const Text('Invite'),
                        ),
                ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(title, style: Theme.of(context).textTheme.titleMedium),
    );
  }
}
