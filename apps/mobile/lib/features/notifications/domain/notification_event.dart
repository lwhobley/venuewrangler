import 'package:flutter/foundation.dart';

@immutable
class NotificationEvent {
  const NotificationEvent({
    required this.id,
    required this.organizationId,
    required this.venueId,
    this.targetUserId,
    required this.audience,
    required this.kind,
    required this.title,
    required this.body,
    this.data = const {},
    this.readAt,
    required this.createdAt,
  });

  final String id;
  final String organizationId;
  final String venueId;
  final String? targetUserId;
  final String audience;
  final String kind;
  final String title;
  final String body;
  final Map<String, dynamic> data;
  final DateTime? readAt;
  final DateTime createdAt;

  bool get isRead => readAt != null;

  factory NotificationEvent.fromMap(Map<String, dynamic> map) {
    return NotificationEvent(
      id: map['id'] as String,
      organizationId: map['organization_id'] as String,
      venueId: map['venue_id'] as String,
      targetUserId: map['target_user_id'] as String?,
      audience: map['audience'] as String? ?? 'user',
      kind: map['kind'] as String? ?? 'general',
      title: map['title'] as String? ?? '',
      body: map['body'] as String? ?? '',
      data: (map['data'] as Map<String, dynamic>?) ?? const {},
      readAt: map['read_at'] != null
          ? DateTime.parse(map['read_at'] as String)
          : null,
      createdAt: DateTime.parse(map['created_at'] as String),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'organization_id': organizationId,
      'venue_id': venueId,
      'target_user_id': targetUserId,
      'audience': audience,
      'kind': kind,
      'title': title,
      'body': body,
      'data': data,
      'read_at': readAt?.toUtc().toIso8601String(),
      'created_at': createdAt.toUtc().toIso8601String(),
    };
  }
}
