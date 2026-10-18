import 'package:flutter/material.dart';

import '../domain/team_member.dart';

/// Bottom sheet listing the roles [member] can be changed to. Returns the chosen role.
Future<String?> showChangeRoleSheet(
  BuildContext context, {
  required TeamMember member,
  required List<String> roles,
}) {
  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
            child: Text(
              'Change role for ${member.name}',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (roles.isEmpty)
            const Padding(
              padding: EdgeInsets.all(24),
              child: Text('There are no other roles you can assign.'),
            ),
          for (final role in roles)
            ListTile(
              title: Text(teamRoleLabel(role)),
              subtitle: Text(_roleBlurb(role)),
              onTap: () => Navigator.of(context).pop(role),
            ),
        ],
      ),
    ),
  );
}

String _roleBlurb(String role) => switch (role) {
      'organization_owner' =>
        'Full control of the organization, billing and team',
      'organization_admin' => 'Manages every venue and the team, not ownership',
      'venue_manager' => 'Manages this venue and its team',
      'supervisor' => 'Runs shifts, no team or billing access',
      _ => 'Their own schedule, clock and tasks',
    };

Future<bool> confirmRemoveMember(
  BuildContext context,
  TeamMember member,
) async {
  final scope = member.isOrgLevel ? 'the whole organization' : 'this venue';
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text('Remove ${member.name}?'),
      content: Text(
        'They lose access to $scope immediately, including guest data, chat '
        'and push notifications. They can be invited again later.',
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
          child: const Text('Remove'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}

/// The word that must be typed to transfer ownership.
const transferConfirmationWord = 'TRANSFER';

Future<bool> confirmTransferOwnership(
  BuildContext context,
  TeamMember member,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => _TransferOwnershipDialog(member: member),
  );
  return confirmed ?? false;
}

class _TransferOwnershipDialog extends StatefulWidget {
  const _TransferOwnershipDialog({required this.member});

  final TeamMember member;

  @override
  State<_TransferOwnershipDialog> createState() =>
      _TransferOwnershipDialogState();
}

class _TransferOwnershipDialogState extends State<_TransferOwnershipDialog> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final matches = _controller.text.trim() == transferConfirmationWord;
    return AlertDialog(
      title: const Text('Make co-owner?'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${widget.member.name} becomes an owner of this organization with '
            'full control of billing, the team and every venue. You stay an '
            'owner until you step down.',
          ),
          const SizedBox(height: 12),
          const Text('Type $transferConfirmationWord to confirm.'),
          const SizedBox(height: 8),
          TextField(
            controller: _controller,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            onChanged: (_) => setState(() {}),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: matches ? () => Navigator.of(context).pop(true) : null,
          child: const Text('Make owner'),
        ),
      ],
    );
  }
}

Future<bool> confirmStepDown(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('Step down to admin?'),
      content: const Text(
        'You keep managing every venue and the team, but lose ownership '
        'powers such as billing and transferring ownership. Another owner '
        'can promote you back.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('Step down'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
