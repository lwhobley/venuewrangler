import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/invites_providers.dart';
import '../domain/pending_invite.dart';

String _countLabel(int count) =>
    count == 1 ? '1 pending invitation' : '$count pending invitations';

/// Card for the venue switcher: shown only while there is something to accept.
class PendingInvitesBanner extends ConsumerWidget {
  const PendingInvitesBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invites = ref.watch(pendingInvitesProvider).valueOrNull ??
        const <PendingInvite>[];
    if (invites.isEmpty) return const SizedBox.shrink();
    final theme = Theme.of(context);
    return Card(
      margin: const EdgeInsets.all(16),
      color: theme.colorScheme.primaryContainer,
      child: ListTile(
        leading: Icon(
          Icons.mail_outline,
          color: theme.colorScheme.onPrimaryContainer,
        ),
        title: Text(
          _headline(invites),
          style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
        ),
        subtitle: Text(
          'Review and join your team.',
          style: TextStyle(color: theme.colorScheme.onPrimaryContainer),
        ),
        trailing: Icon(
          Icons.chevron_right,
          color: theme.colorScheme.onPrimaryContainer,
        ),
        onTap: () => context.push('/invites'),
      ),
    );
  }
}

String _headline(List<PendingInvite> invites) => invites.length == 1
    ? "You're invited to join ${invites.single.venueName}"
    : 'You have ${_countLabel(invites.length)}';

/// Wraps the tab shell (app/app_shell.dart): while invitations are waiting, a banner sits above
/// every tab so someone who already has a venue still sees them (launch review A1: they used
/// to be reachable only through the venue switcher icon). "Later" hides it for this session.
class PendingInvitesShellBanner extends ConsumerWidget {
  const PendingInvitesShellBanner({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invites = ref.watch(pendingInvitesProvider).valueOrNull ??
        const <PendingInvite>[];
    if (invites.isEmpty || ref.watch(invitesBannerDismissedProvider)) {
      return child;
    }
    final theme = Theme.of(context);
    final onBanner = theme.colorScheme.onPrimaryContainer;
    return Column(
      children: [
        Material(
          color: theme.colorScheme.primaryContainer,
          child: SafeArea(
            bottom: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
              child: Row(
                children: [
                  Icon(Icons.mail_outline, color: onBanner),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _headline(invites),
                      style:
                          theme.textTheme.bodyMedium?.copyWith(color: onBanner),
                    ),
                  ),
                  TextButton(
                    onPressed: () => ref
                        .read(invitesBannerDismissedProvider.notifier)
                        .state = true,
                    child: Text('Later', style: TextStyle(color: onBanner)),
                  ),
                  FilledButton(
                    onPressed: () => context.push('/invites'),
                    child: const Text('View'),
                  ),
                ],
              ),
            ),
          ),
        ),
        // The banner already took the status-bar inset.
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}

/// Settings row for invitations; hidden when there are none.
class PendingInvitesSettingsTile extends ConsumerWidget {
  const PendingInvitesSettingsTile({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingInvitesProvider).valueOrNull?.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return ListTile(
      leading: const Icon(Icons.mail_outline),
      title: const Text('Invitations'),
      subtitle: Text(_countLabel(count)),
      trailing: const Icon(Icons.chevron_right),
      onTap: () => context.push('/invites'),
    );
  }
}
