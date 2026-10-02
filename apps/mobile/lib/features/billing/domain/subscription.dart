/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
class Subscription {
  const Subscription({
    required this.organizationId,
    required this.status,
    this.currentPeriodEnd,
    required this.cancelAtPeriodEnd,
  });

  final String organizationId;
  final String status;
  final DateTime? currentPeriodEnd;
  final bool cancelAtPeriodEnd;

  bool get isEntitled => status == 'active' || status == 'trialing';

  factory Subscription.fromJson(Map<String, dynamic> json) => Subscription(
        organizationId: json['organization_id'] as String,
        status: json['status'] as String,
        currentPeriodEnd: json['current_period_end'] == null
            ? null
            : DateTime.parse(json['current_period_end'] as String),
        cancelAtPeriodEnd: json['cancel_at_period_end'] as bool? ?? false,
      );
}
