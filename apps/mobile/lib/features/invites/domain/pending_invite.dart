/// One row of `public.my_pending_invites()`: an invite addressed to the signed-in user's
/// verified email that has not been accepted yet.
class PendingInvite {
  const PendingInvite({
    required this.inviteId,
    required this.organizationId,
    required this.organizationName,
    required this.venueId,
    required this.venueName,
    required this.role,
    this.invitedAt,
    this.invitedByName,
    this.expiresAt,
  });

  final String inviteId;
  final String organizationId;
  final String organizationName;
  final String venueId;
  final String venueName;
  final String role;
  final DateTime? invitedAt;

  /// The inviting manager's display name, when they have one.
  final String? invitedByName;
  final DateTime? expiresAt;

  factory PendingInvite.fromJson(Map<String, dynamic> json) => PendingInvite(
        inviteId: json['invite_id'] as String,
        organizationId: json['organization_id'] as String,
        organizationName:
            json['organization_name'] as String? ?? 'Organization',
        venueId: json['venue_id'] as String,
        venueName: json['venue_name'] as String? ?? 'Venue',
        role: json['role'] as String,
        invitedAt: DateTime.tryParse(json['invited_at'] as String? ?? ''),
        invitedByName: json['invited_by_name'] as String?,
        expiresAt: DateTime.tryParse(json['expires_at'] as String? ?? ''),
      );
}
