import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/invites_providers.dart';

String _countLabel(int count) =>
    count == 1 ? '1 pending invitation' : '$count pending invitations';

/// Card for the venue switcher: shown only while there is something to accept.
class PendingInvitesBanner extends ConsumerWidget {
  const PendingInvitesBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = ref.watch(pendingInvitesProvider).valueOrNull?.length ?? 0;
    if (count == 0) return const SizedBox.shrink();
    return Card(
      margin: const EdgeInsets.all(16),
      child: ListTile(
        leading: const Icon(Icons.mail_outline),
        title: Text('You have ${_countLabel(count)}'),
        subtitle: const Text('Review and accept to join a venue.'),
        trailing: const Icon(Icons.chevron_right),
        onTap: () => context.push('/invites'),
      ),
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
