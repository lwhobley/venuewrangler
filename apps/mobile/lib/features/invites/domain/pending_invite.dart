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
  });

  final String inviteId;
  final String organizationId;
  final String organizationName;
  final String venueId;
  final String venueName;
  final String role;
  final DateTime? invitedAt;

  factory PendingInvite.fromJson(Map<String, dynamic> json) => PendingInvite(
        inviteId: json['invite_id'] as String,
        organizationId: json['organization_id'] as String,
        organizationName:
            json['organization_name'] as String? ?? 'Organization',
        venueId: json['venue_id'] as String,
        venueName: json['venue_name'] as String? ?? 'Venue',
        role: json['role'] as String,
        invitedAt: DateTime.tryParse(json['invited_at'] as String? ?? ''),
      );
}
