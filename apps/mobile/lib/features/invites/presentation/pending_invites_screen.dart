import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/sign_out_service.dart';
import '../../../core/widgets/state_views.dart';
import '../../organizations/application/workspace_provisioning.dart';
import '../../team/domain/team_member.dart';
import '../../venues/application/venues_providers.dart';
import '../application/invites_providers.dart';
import '../data/invites_repository.dart';
import '../domain/pending_invite.dart';

/// Invitations addressed to the signed-in user's email. Nothing is joined until the person
/// taps Join. Reached automatically when they have an invite and no workspace (see
/// app/router.dart), from an invitation link while signed in ([highlightInviteId]), and from
/// the in-app banner and Settings otherwise.
class PendingInvitesScreen extends ConsumerStatefulWidget {
  const PendingInvitesScreen({super.key, this.highlightInviteId});

  /// The invite from the link the person opened; listed first.
  final String? highlightInviteId;

  @override
  ConsumerState<PendingInvitesScreen> createState() =>
      _PendingInvitesScreenState();
}

class _PendingInvitesScreenState extends ConsumerState<PendingInvitesScreen> {
  String? _acceptingId;

  bool get _hasVenue => ref.read(activeVenueProvider) != null;

  void _leave() {
    // Stop the router from steering back here, then go to where the person was headed.
    ref.read(invitesPromptDismissedProvider.notifier).state = true;
    if (_hasVenue && context.canPop()) {
      context.pop();
    } else {
      context.go(_hasVenue ? '/' : '/select-venue');
    }
  }

  Future<void> _accept(PendingInvite invite) async {
    setState(() => _acceptingId = invite.inviteId);
    final messenger = ScaffoldMessenger.of(context);
    // Read before the await: the controllers outlive this screen if it is closed meanwhile.
    final redemption = ref.read(inviteRedemptionProvider.notifier);
    final provisioning = ref.read(workspaceProvisioningProvider.notifier);
    try {
      final venue = await redemption.accept(invite);
      await provisioning.discardHeldWorkspace();
      messenger.showSnackBar(
        SnackBar(content: Text('You joined ${invite.venueName}.')),
      );
      if (!mounted) return;
      final remaining =
          ref.read(pendingInvitesProvider).valueOrNull ?? const [];
      // Straight into the venue they joined (accept made it the active venue).
      if (venue != null) {
        context.go('/');
      } else if (remaining.isEmpty) {
        _leave();
      }
    } on InviteException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _acceptingId = null);
    }
  }

  Future<void> _createHeldWorkspace() async {
    ref.read(invitesPromptDismissedProvider.notifier).state = true;
    final provisioning = ref.read(workspaceProvisioningProvider.notifier);
    context.go('/select-venue');
    // The switcher shows progress and any failure (workspaceProvisioningProvider).
    await provisioning.createHeldWorkspace();
  }

  @override
  Widget build(BuildContext context) {
    final invitesAsync = ref.watch(pendingInvitesProvider);
    final heldWorkspace = ref.watch(
      workspaceProvisioningProvider.select((state) => state.heldName),
    );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Invitations'),
        actions: [
          if (!_hasVenue)
            IconButton(
              icon: const Icon(Icons.logout),
              tooltip: 'Sign out',
              onPressed: () => signOutAndClearScopedData(
                ProviderScope.containerOf(context, listen: false),
              ),
            ),
        ],
      ),
      body: invitesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ErrorState(
          message: 'Could not load your invitations.',
          onRetry: () => ref.invalidate(pendingInvitesProvider),
        ),
        data: (invites) {
          if (invites.isEmpty) {
            return EmptyState(
              icon: Icons.mark_email_read_outlined,
              message: widget.highlightInviteId == null
                  ? 'No pending invitations.'
                  : InviteRedemptionController.noInviteFound,
              action: OutlinedButton(
                onPressed: _leave,
                child: const Text('Continue'),
              ),
            );
          }
          final ordered = [
            ...invites.where((i) => i.inviteId == widget.highlightInviteId),
            ...invites.where((i) => i.inviteId != widget.highlightInviteId),
          ];
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Text(
                invites.length == 1
                    ? 'You have been invited to join a team.'
                    : 'You have been invited to join these teams.',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 4),
              Text(
                'Join only the teams you expect: joining gives that venue '
                'access to your name and lets you see its schedule and floor.',
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 12),
              for (final invite in ordered)
                _InviteCard(
                  invite: invite,
                  busy: _acceptingId == invite.inviteId,
                  disabled: _acceptingId != null,
                  onAccept: () => _accept(invite),
                ),
              const SizedBox(height: 8),
              if (heldWorkspace != null)
                OutlinedButton(
                  onPressed: _acceptingId == null ? _createHeldWorkspace : null,
                  child: Text('Create “$heldWorkspace” as a new workspace'),
                ),
              TextButton(
                onPressed: _acceptingId == null ? _leave : null,
                child: const Text('Decide later'),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _InviteCard extends StatelessWidget {
  const _InviteCard({
    required this.invite,
    required this.busy,
    required this.disabled,
    required this.onAccept,
  });

  final PendingInvite invite;
  final bool busy;
  final bool disabled;
  final VoidCallback onAccept;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    final expires = invite.expiresAt;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(invite.venueName, style: theme.textTheme.titleMedium),
            const SizedBox(height: 2),
            Text(
              '${invite.organizationName} · as ${teamRoleLabel(invite.role)}',
              style: muted,
            ),
            if (invite.invitedByName != null || expires != null) ...[
              const SizedBox(height: 2),
              Text(
                [
                  if (invite.invitedByName != null)
                    'Invited by ${invite.invitedByName}',
                  if (expires != null)
                    'expires ${MaterialLocalizations.of(context).formatShortMonthDay(expires.toLocal())}',
                ].join(' · '),
                style: muted,
              ),
            ],
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: FilledButton(
                onPressed: disabled ? null : onAccept,
                child: busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : Text('Join ${invite.venueName}'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
