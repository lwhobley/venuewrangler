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

  /// Roles someone holding [actorRole] may invite. Owner decision (launch review): only
  /// organization owners/admins may invite managers; the database enforces the same rule
  /// (app_hidden.can_manage_member_role).
  static List<WorkforceRole> invitableBy(String? actorRole) =>
      actorRole == 'organization_owner' || actorRole == 'organization_admin'
          ? WorkforceRole.values
          : const [WorkforceRole.supervisor, WorkforceRole.staff];
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
    return RosterMember(
      userId: json['user_id'] as String,
      role: json['role'] as String,
      displayName: json['display_name'] as String?,
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
    this.fullName,
    this.expiresAt,
    this.lastSentAt,
  });

  final String id;
  final String venueId;
  final String email;
  final WorkforceRole role;
  final InviteStatus status;
  final DateTime createdAt;

  /// The invitee's name as the manager typed it; becomes their display name on joining.
  final String? fullName;
  final DateTime? expiresAt;

  /// When invite-send-email last delivered it; null if it was never emailed.
  final DateTime? lastSentAt;

  /// Still `pending` in the database but past its expiry: it can no longer be accepted and
  /// should be resent.
  bool isExpiredAt(DateTime now) =>
      status == InviteStatus.expired ||
      (expiresAt != null && !expiresAt!.isAfter(now));

  factory Invite.fromJson(Map<String, dynamic> json) => Invite(
        id: json['id'] as String,
        venueId: json['venue_id'] as String,
        email: json['email'] as String,
        role: WorkforceRole.fromDb(json['role'] as String),
        status: InviteStatus.fromDb(json['status'] as String),
        createdAt: DateTime.parse(json['created_at'] as String),
        fullName: json['full_name'] as String?,
        expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
        lastSentAt: DateTime.tryParse(json['last_sent_at'] as String? ?? ''),
      );
}
