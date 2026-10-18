import 'package:flutter/material.dart';

import '../domain/team_member.dart';

enum TeamMemberAction { changeRole, remove, transferOwnership, stepDown }

/// One member row: name, role, and (when the caller may manage them) an actions menu.
class TeamMemberTile extends StatelessWidget {
  const TeamMemberTile({
    super.key,
    required this.member,
    required this.isSelf,
    required this.actions,
    required this.onAction,
  });

  final TeamMember member;
  final bool isSelf;

  /// Empty hides the menu.
  final List<TeamMemberAction> actions;
  final void Function(TeamMemberAction action) onAction;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: CircleAvatar(
        child: Text(member.name.characters.first.toUpperCase()),
      ),
      title: Text(isSelf ? '${member.name} (you)' : member.name),
      subtitle: Text(teamRoleLabel(member.role)),
      trailing: actions.isEmpty
          ? null
          : PopupMenuButton<TeamMemberAction>(
              tooltip: 'Actions for ${member.name}',
              onSelected: onAction,
              itemBuilder: (context) => [
                for (final action in actions)
                  PopupMenuItem(value: action, child: Text(_label(action))),
              ],
            ),
    );
  }

  String _label(TeamMemberAction action) => switch (action) {
        TeamMemberAction.changeRole => 'Change role',
        TeamMemberAction.remove => 'Remove from team',
        TeamMemberAction.transferOwnership => 'Make co-owner',
        TeamMemberAction.stepDown => 'Step down to admin',
      };
}
