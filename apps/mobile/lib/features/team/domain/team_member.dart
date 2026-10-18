/// Roles from most to least privileged. Same order as `venues_providers.dart`'s ranking.
const teamRoleRank = [
  'organization_owner',
  'organization_admin',
  'venue_manager',
  'supervisor',
  'staff',
];

/// Roles an org-level membership (no venue) may hold.
const orgLevelRoles = ['organization_owner', 'organization_admin'];

/// Roles a venue-level membership may hold.
const venueLevelRoles = ['venue_manager', 'supervisor', 'staff'];

/// Roles that may open the Team screen. Supervisors and staff do not see it.
const teamManagerRoles = {
  'venue_manager',
  'organization_admin',
  'organization_owner',
};

String teamRoleLabel(String role) => switch (role) {
      'organization_owner' => 'Owner',
      'organization_admin' => 'Admin',
      'venue_manager' => 'Manager',
      'supervisor' => 'Supervisor',
      'staff' => 'Staff',
      _ => role,
    };

int _rank(String? role) {
  final index = teamRoleRank.indexOf(role ?? '');
  return index < 0 ? teamRoleRank.length : index;
}

/// One row of `public.team_members(p_venue_id)`: a membership on the venue, or an owner/admin
/// membership on its organization ([venueId] null).
class TeamMember {
  const TeamMember({
    required this.membershipId,
    required this.userId,
    required this.role,
    required this.organizationId,
    this.displayName,
    this.venueId,
  });

  final String membershipId;
  final String userId;
  final String role;
  final String organizationId;
  final String? displayName;

  /// Null for organization-level owners and admins.
  final String? venueId;

  bool get isOrgLevel => venueId == null;

  String get name => (displayName == null || displayName!.trim().isEmpty)
      ? 'Unnamed member'
      : displayName!;

  factory TeamMember.fromJson(Map<String, dynamic> json) => TeamMember(
        membershipId: json['membership_id'] as String,
        userId: json['user_id'] as String,
        role: json['role'] as String,
        organizationId: json['organization_id'] as String,
        displayName: json['display_name'] as String?,
        venueId: json['venue_id'] as String?,
      );

  /// Whether the caller should be offered management actions for this row. A hint only: the
  /// server decides (`42501`), and a person can never manage their own membership here.
  bool canBeManagedBy({required String? callerRole, required String callerId}) {
    if (userId == callerId || !teamManagerRoles.contains(callerRole)) {
      return false;
    }
    if (callerRole == 'organization_owner') return true;
    if (callerRole == 'venue_manager' && isOrgLevel) return false;
    return _rank(callerRole) < _rank(role);
  }

  /// Roles this row may be changed to by the caller: the row's own level, never above the
  /// caller's own role, excluding the current role.
  List<String> assignableRolesFor(String? callerRole) => [
        for (final candidate in isOrgLevel ? orgLevelRoles : venueLevelRoles)
          if (candidate != role && _rank(candidate) >= _rank(callerRole))
            candidate,
      ];
}
