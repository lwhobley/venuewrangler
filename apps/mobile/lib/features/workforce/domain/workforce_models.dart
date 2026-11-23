/// See the note in features/organizations/domain/organization.dart about why these are
/// hand-written models rather than `freezed` for now.
enum WorkforceRole {
  venueManager,
  supervisor,
  staff;

  static WorkforceRole fromDb(String value) {
    final role = tryFromDb(value);
    if (role == null) {
      throw ArgumentError('Unknown workforce role: $value');
    }
    return role;
  }

  /// Returns null for unexpected / legacy DB values instead of throwing.
  static WorkforceRole? tryFromDb(String value) => switch (value) {
    'venue_manager' => WorkforceRole.venueManager,
    'supervisor' => WorkforceRole.supervisor,
    'staff' => WorkforceRole.staff,
    _ => null,
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
  });

  final String id;
  final String venueId;
  final String email;
  final WorkforceRole role;
  final InviteStatus status;
  final DateTime createdAt;

  factory Invite.fromJson(Map<String, dynamic> json) {
    final invite = tryFromJson(json);
    if (invite == null) {
      throw ArgumentError('Could not parse invite: ${json['id']}');
    }
    return invite;
  }

  /// Parses an invite row, or returns null when role/status are unknown so one
  /// legacy row cannot fail the whole invites list.
  static Invite? tryFromJson(Map<String, dynamic> json) {
    final role = WorkforceRole.tryFromDb(json['role'] as String);
    if (role == null) return null;

    final InviteStatus status;
    if (json['status'] == 'pending' &&
        json['expires_at'] != null &&
        DateTime.parse(json['expires_at'] as String).isBefore(DateTime.now())) {
      status = InviteStatus.expired;
    } else {
      try {
        status = InviteStatus.fromDb(json['status'] as String);
      } on ArgumentError {
        return null;
      }
    }

    return Invite(
      id: json['id'] as String,
      venueId: json['venue_id'] as String,
      email: json['email'] as String,
      role: role,
      status: status,
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
