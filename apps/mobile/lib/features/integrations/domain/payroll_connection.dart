/// See the note in features/organizations/domain/organization.dart about why this is a
/// hand-written model rather than `freezed` for now.
enum PayrollProvider {
  square,
  quickbooks,
  gusto;

  String toDb() => name;

  /// The `{provider}-oauth` Edge Function slug this provider's connect/disconnect calls go to.
  String get functionSlug => '$name-oauth';

  String get label => switch (this) {
        PayrollProvider.square => 'Square',
        PayrollProvider.quickbooks => 'QuickBooks',
        PayrollProvider.gusto => 'Gusto',
      };
}

class PayrollConnection {
  const PayrollConnection({
    required this.venueId,
    required this.provider,
    required this.status,
    this.externalAccountId,
    this.tokenExpiresAt,
    this.lastError,
  });

  final String venueId;
  final String provider;
  final String status;
  final String? externalAccountId;
  final DateTime? tokenExpiresAt;
  final String? lastError;

  bool get isConnected => status == 'connected';

  factory PayrollConnection.fromJson(Map<String, dynamic> json) => PayrollConnection(
        venueId: json['venue_id'] as String,
        provider: json['provider'] as String,
        status: json['status'] as String,
        externalAccountId: json['external_account_id'] as String?,
        tokenExpiresAt: json['token_expires_at'] == null
            ? null
            : DateTime.parse(json['token_expires_at'] as String),
        lastError: json['last_error'] as String?,
      );
}
