import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/auth/sign_out_service.dart';
import '../../../core/widgets/state_views.dart';
import '../../team/domain/team_member.dart';
import '../../venues/application/venues_providers.dart';
import '../application/invites_providers.dart';
import '../data/invites_repository.dart';
import '../domain/pending_invite.dart';

/// Invitations addressed to the signed-in user's email. Nothing is joined until the person
/// accepts. Reached automatically when they have an invite and no workspace (see
/// app/router.dart) and from Settings otherwise.
class PendingInvitesScreen extends ConsumerStatefulWidget {
  const PendingInvitesScreen({super.key});

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
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await acceptInvite(container, invite.inviteId);
      messenger.showSnackBar(
        SnackBar(content: Text('You joined ${invite.venueName}.')),
      );
      if (!mounted) return;
      final remaining =
          ref.read(pendingInvitesProvider).valueOrNull ?? const [];
      if (remaining.isEmpty) _leave();
    } on InviteException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      if (mounted) setState(() => _acceptingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invitesAsync = ref.watch(pendingInvitesProvider);
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
        data: (invites) => invites.isEmpty
            ? EmptyState(
                icon: Icons.mark_email_read_outlined,
                message: 'No pending invitations.',
                action: OutlinedButton(
                  onPressed: _leave,
                  child: const Text('Continue'),
                ),
              )
            : ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  Text(
                    'You have been invited to join. Accept only the invitations '
                    'you expect: accepting gives access to that venue.',
                    style: Theme.of(context).textTheme.bodyMedium,
                  ),
                  const SizedBox(height: 12),
                  for (final invite in invites)
                    _InviteCard(
                      invite: invite,
                      busy: _acceptingId == invite.inviteId,
                      disabled: _acceptingId != null,
                      onAccept: () => _accept(invite),
                    ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: _acceptingId == null ? _leave : null,
                    child: const Text('Decide later'),
                  ),
                ],
              ),
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
              style: theme.textTheme.bodyMedium
                  ?.copyWith(color: theme.colorScheme.onSurfaceVariant),
            ),
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
                    : const Text('Accept'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
