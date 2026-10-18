import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/team_error.dart';
import '../domain/team_member.dart';

/// Membership management through the `SECURITY DEFINER` RPCs (`memberships` has no client
/// write policy). The server decides who may do what; every failure surfaces as a
/// [TeamException] with a message fit to show.
abstract interface class TeamRepository {
  /// Members of [venueId] plus the organization-level owners and admins
  /// (`public.team_members`).
  Future<List<TeamMember>> fetchMembers(String venueId);

  /// `public.remove_member`: revokes access (and chat/push) for that membership.
  Future<void> removeMember(String membershipId);

  /// `public.change_member_role`: [newRole] must be allowed for that row's level.
  Future<void> changeRole(String membershipId, String newRole);

  /// `public.transfer_ownership`: makes [newOwnerUserId] an owner of the organization.
  Future<void> transferOwnership({
    required String organizationId,
    required String newOwnerUserId,
  });
}

class SupabaseTeamRepository implements TeamRepository {
  const SupabaseTeamRepository(this._client);

  final SupabaseClient _client;

  Future<T> _call<T>(Future<T> Function() request) async {
    try {
      return await request();
    } catch (error) {
      throw teamExceptionFrom(error);
    }
  }

  @override
  Future<List<TeamMember>> fetchMembers(String venueId) => _call(() async {
        final rows = await _client.rpc(
          'team_members',
          params: {'p_venue_id': venueId},
        ) as List<dynamic>;
        return [
          for (final row in rows)
            TeamMember.fromJson(Map<String, dynamic>.from(row as Map)),
        ];
      });

  @override
  Future<void> removeMember(String membershipId) => _call(
        () => _client.rpc(
          'remove_member',
          params: {'p_membership_id': membershipId},
        ),
      );

  @override
  Future<void> changeRole(String membershipId, String newRole) => _call(
        () => _client.rpc(
          'change_member_role',
          params: {'p_membership_id': membershipId, 'p_new_role': newRole},
        ),
      );

  @override
  Future<void> transferOwnership({
    required String organizationId,
    required String newOwnerUserId,
  }) =>
      _call(
        () => _client.rpc(
          'transfer_ownership',
          params: {
            'p_organization_id': organizationId,
            'p_new_owner_user_id': newOwnerUserId,
          },
        ),
      );
}
