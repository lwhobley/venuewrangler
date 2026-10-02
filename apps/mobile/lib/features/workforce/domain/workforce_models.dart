/// See the note in features/organizations/domain/organization.dart about why these are
/// hand-written models rather than `freezed` for now.
enum WorkforceRole {
  venueManager,
  supervisor,
  staff;

  static WorkforceRole fromDb(String value) => switch (value) {
        'venue_manager' => WorkforceRole.venueManager,
        'supervisor' => WorkforceRole.supervisor,
        'staff' => WorkforceRole.staff,
        _ => throw ArgumentError('Unknown workforce role: $value'),
      };

  String toDb() => switch (this) {
        WorkforceRole.venueManager => 'venue_manager',
        WorkforceRole.supervisor => 'supervisor',
        WorkforceRole.staff => 'staff',
      };

  String get label => switch (this) {
        WorkforceRole.venueManager => 'Venue manager',
        WorkforceRole.supervisor => 'Supervisor',
        WorkforceRole.staff => 'Staff',
      };
}

/// One row of a venue's roster: a membership joined with the member's profile. There is no
/// separate "staff" table — `memberships` (supabase/migrations/20261002000000) plus
/// `profiles` is the roster, per the note in workforce_invites.sql.
class RosterMember {
  const RosterMember({
    required this.userId,
    required this.role,
    this.displayName,
  });

  final String userId;
  final String role;
  final String? displayName;

  factory RosterMember.fromJson(Map<String, dynamic> json) {
    final profile = json['profiles'];
    return RosterMember(
      userId: json['user_id'] as String,
      role: json['role'] as String,
      displayName: profile is Map<String, dynamic> ? profile['display_name'] as String? : null,
    );
  }
}

enum InviteStatus {
  pending,
  accepted,
  revoked,
  expired;

  static InviteStatus fromDb(String value) => switch (value) {
        'pending' => InviteStatus.pending,
        'accepted' => InviteStatus.accepted,
        'revoked' => InviteStatus.revoked,
        'expired' => InviteStatus.expired,
        _ => throw ArgumentError('Unknown invite status: $value'),
      };
}

class Invite {
  const Invite({
    required this.id,
    required this.venueId,
    required this.email,
    required this.role,
    required this.status,
    required this.createdAt,
  });

  final String id;
  final String venueId;
  final String email;
  final WorkforceRole role;
  final InviteStatus status;
  final DateTime createdAt;

  factory Invite.fromJson(Map<String, dynamic> json) => Invite(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        email: json['email'] as String,
        role: WorkforceRole.fromDb(json['role'] as String),
        status: InviteStatus.fromDb(json['status'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}
