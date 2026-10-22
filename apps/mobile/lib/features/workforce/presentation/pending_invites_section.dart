import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/theme/ops_colors.dart';
import '../application/workforce_providers.dart';
import '../data/workforce_repository.dart';
import '../domain/workforce_models.dart';
import 'invite_staff_dialog.dart';

/// The roster's "Pending invites" list: who was invited, whether the email went out, and
/// whether the invite expired, with Resend (replaces an expired invite) and Revoke.
class PendingInvitesSection extends ConsumerStatefulWidget {
  const PendingInvitesSection({
    super.key,
    required this.venueId,
    required this.actorRole,
  });

  final String venueId;
  final String? actorRole;

  @override
  ConsumerState<PendingInvitesSection> createState() =>
      _PendingInvitesSectionState();
}

class _PendingInvitesSectionState extends ConsumerState<PendingInvitesSection> {
  String? _busyId;

  /// Managers see owner-issued manager invites but cannot act on them (the database refuses).
  bool _canManage(Invite invite) =>
      WorkforceRole.invitableBy(widget.actorRole).contains(invite.role);

  Future<void> _resend(Invite invite) async {
    setState(() => _busyId = invite.id);
    final messenger = ScaffoldMessenger.of(context);
    final repository = ref.read(workforceRepositoryProvider);
    try {
      final fresh = await repository.resendInvite(invite.id);
      final outcome = await deliverInvite(repository, fresh);
      messenger.showSnackBar(SnackBar(content: Text(outcome.message)));
    } on InviteActionException catch (error) {
      messenger.showSnackBar(SnackBar(content: Text(error.message)));
    } finally {
      ref.invalidate(invitesForVenueProvider(widget.venueId));
      if (mounted) setState(() => _busyId = null);
    }
  }

  Future<void> _revoke(Invite invite) async {
    setState(() => _busyId = invite.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(workforceRepositoryProvider).revokeInvite(invite.id);
    } on PostgrestException catch (_) {
      messenger.showSnackBar(
        const SnackBar(
          content: Text("You don't have permission to revoke this invite."),
        ),
      );
    } finally {
      ref.invalidate(invitesForVenueProvider(widget.venueId));
      if (mounted) setState(() => _busyId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final invitesAsync = ref.watch(invitesForVenueProvider(widget.venueId));
    return invitesAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const ListTile(title: Text('Could not load invites.')),
      data: (invites) {
        // Rows already replaced by a newer invite are 'expired'/'revoked'; only the current
        // one per person is shown (a pending row may itself be past its expiry).
        final pending = invites
            .where((invite) => invite.status == InviteStatus.pending)
            .toList();
        if (pending.isEmpty) {
          return const ListTile(title: Text('No pending invites.'));
        }
        final now = DateTime.now();
        return Column(
          children: [
            for (final invite in pending)
              _InviteTile(
                invite: invite,
                expired: invite.isExpiredAt(now),
                busy: _busyId == invite.id,
                onResend: _canManage(invite) && _busyId == null
                    ? () => _resend(invite)
                    : null,
                onRevoke: _canManage(invite) && _busyId == null
                    ? () => _revoke(invite)
                    : null,
              ),
          ],
        );
      },
    );
  }
}

class _InviteTile extends StatelessWidget {
  const _InviteTile({
    required this.invite,
    required this.expired,
    required this.busy,
    required this.onResend,
    required this.onRevoke,
  });

  final Invite invite;
  final bool expired;
  final bool busy;
  final VoidCallback? onResend;
  final VoidCallback? onRevoke;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final localizations = MaterialLocalizations.of(context);
    String day(DateTime value) =>
        localizations.formatShortMonthDay(value.toLocal());
    final status = expired
        ? 'Expired${invite.expiresAt == null ? '' : ' ${day(invite.expiresAt!)}'}'
        : [
            invite.lastSentAt == null
                ? 'Not emailed yet'
                : 'Emailed ${day(invite.lastSentAt!)}',
            if (invite.expiresAt != null) 'expires ${day(invite.expiresAt!)}',
          ].join(' · ');
    final name = invite.fullName;
    final muted = theme.textTheme.bodyMedium
        ?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 8, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 2, right: 16),
            child: Icon(
              expired ? Icons.schedule : Icons.mail_outline,
              color: expired ? context.ops.warning.fg : null,
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(name ?? invite.email, style: theme.textTheme.bodyLarge),
                Text(
                  [if (name != null) invite.email, invite.role.label]
                      .join(' · '),
                  style: muted,
                ),
                Text(
                  status,
                  style: expired
                      ? muted?.copyWith(color: context.ops.warning.fg)
                      : muted,
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(12),
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        )
                      : Wrap(
                          children: [
                            TextButton(
                              onPressed: onResend,
                              child: Text(
                                expired ? 'Send a new invite' : 'Resend',
                              ),
                            ),
                            TextButton(
                              onPressed: onRevoke,
                              child: const Text('Revoke'),
                            ),
                          ],
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
