import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/widgets/state_views.dart';
import '../../venues/application/venues_providers.dart';
import '../application/team_providers.dart';
import '../domain/team_error.dart';
import '../domain/team_member.dart';
import 'team_dialogs.dart';
import 'team_member_tile.dart';

/// Who has access to the active venue, with the controls the security audit (C-02) found
/// missing: change a role, remove someone (immediate deprovisioning), transfer ownership.
/// Visible to venue managers, org admins and owners only; the server re-checks every action.
class TeamScreen extends ConsumerWidget {
  const TeamScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    final role = ref.watch(myVenueRoleProvider).valueOrNull;
    final userId = ref.watch(currentUserIdProvider);

    if (venue == null || userId == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }
    if (!teamManagerRoles.contains(role)) {
      return Scaffold(
        appBar: AppBar(title: const Text('Team')),
        body: const EmptyState(
          icon: Icons.lock_outline,
          message: 'Only managers and owners can manage the team.',
        ),
      );
    }

    final membersAsync = ref.watch(teamMembersProvider(venue.id));
    return Scaffold(
      appBar: AppBar(title: const Text('Team')),
      body: membersAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => ErrorState(
          message: teamExceptionFrom(error).message,
          onRetry: () => ref.invalidate(teamMembersProvider(venue.id)),
        ),
        data: (members) => RefreshIndicator(
          onRefresh: () => ref.refresh(teamMembersProvider(venue.id).future),
          child: _MemberList(
            members: members,
            callerRole: role,
            callerId: userId,
            venueId: venue.id,
          ),
        ),
      ),
    );
  }
}

class _MemberList extends ConsumerWidget {
  const _MemberList({
    required this.members,
    required this.callerRole,
    required this.callerId,
    required this.venueId,
  });

  final List<TeamMember> members;
  final String? callerRole;
  final String callerId;
  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final orgLevel = members.where((m) => m.isOrgLevel).toList();
    final venueLevel = members.where((m) => !m.isOrgLevel).toList();
    final theme = Theme.of(context);

    Widget header(String text) => Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
          child: Text(text.toUpperCase(), style: theme.textTheme.labelSmall),
        );

    Iterable<Widget> tiles(List<TeamMember> list) => list.map(
          (member) => TeamMemberTile(
            key: ValueKey(member.membershipId),
            member: member,
            isSelf: member.userId == callerId,
            actions: _actionsFor(member),
            onAction: (action) => _run(context, ref, member, action),
          ),
        );

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        if (orgLevel.isNotEmpty) ...[
          header('Organization owners and admins'),
          ...tiles(orgLevel),
        ],
        header('This venue'),
        if (venueLevel.isEmpty)
          const ListTile(title: Text('No venue-level members yet.')),
        ...tiles(venueLevel),
        Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'To leave an organization yourself, delete your account from '
            'Settings. New people join through an invite.',
            style: theme.textTheme.bodySmall,
          ),
        ),
      ],
    );
  }

  List<TeamMemberAction> _actionsFor(TeamMember member) {
    // The one change a person may make to themselves: an owner stepping down once another
    // owner exists (the server re-checks, including `last_owner`).
    if (member.userId == callerId &&
        member.isOrgLevel &&
        member.role == 'organization_owner') {
      final otherOwner = members.any(
        (m) => m.userId != callerId && m.role == 'organization_owner',
      );
      return otherOwner ? const [TeamMemberAction.stepDown] : const [];
    }
    if (!member.canBeManagedBy(callerRole: callerRole, callerId: callerId)) {
      return const [];
    }
    return [
      if (member.assignableRolesFor(callerRole).isNotEmpty)
        TeamMemberAction.changeRole,
      TeamMemberAction.remove,
      if (callerRole == 'organization_owner')
        TeamMemberAction.transferOwnership,
    ];
  }

  Future<void> _run(
    BuildContext context,
    WidgetRef ref,
    TeamMember member,
    TeamMemberAction action,
  ) async {
    final repository = ref.read(teamRepositoryProvider);
    // Captured before any await: the list can rebuild while a dialog or request is open.
    final container = ProviderScope.containerOf(context, listen: false);
    final messenger = ScaffoldMessenger.of(context);
    final Future<void> Function() request;
    final String success;

    switch (action) {
      case TeamMemberAction.changeRole:
        final role = await showChangeRoleSheet(
          context,
          member: member,
          roles: member.assignableRolesFor(callerRole),
        );
        if (role == null) return;
        request = () => repository.changeRole(member.membershipId, role);
        success = '${member.name} is now ${teamRoleLabel(role)}.';
      case TeamMemberAction.stepDown:
        if (!await confirmStepDown(context)) return;
        request = () => repository.changeRole(
              member.membershipId,
              'organization_admin',
            );
        success = 'You are now an admin.';
      case TeamMemberAction.remove:
        if (!await confirmRemoveMember(context, member)) return;
        request = () => repository.removeMember(member.membershipId);
        success = '${member.name} was removed.';
      case TeamMemberAction.transferOwnership:
        if (!await confirmTransferOwnership(context, member)) return;
        request = () => repository.transferOwnership(
              organizationId: member.organizationId,
              newOwnerUserId: member.userId,
            );
        success = '${member.name} is now a co-owner.';
    }

    try {
      await request();
      messenger.showSnackBar(SnackBar(content: Text(success)));
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(teamExceptionFrom(error).message)),
      );
    } finally {
      // Either way the server state may have changed (or been refused for a stale list).
      container.invalidate(teamMembersProvider(venueId));
      if (action == TeamMemberAction.stepDown) {
        container.invalidate(myVenueRoleProvider);
      }
    }
  }
}
