/// A queued write that could not reach Supabase yet. `kind` identifies which feature's
/// handler should apply it (see `OfflineQueueController`'s handler registry) — this file
/// stays feature-agnostic on purpose, so the queue itself doesn't need to know what a
/// "task status update" or "checklist response" is.
class PendingMutation {
  const PendingMutation({
    required this.id,
    required this.kind,
    required this.payload,
    required this.createdAt,
    this.attemptCount = 0,
    this.userId,
  });

  final String id;
  final String kind;
  final Map<String, dynamic> payload;
  final DateTime createdAt;
  final int attemptCount;

  /// Owner who queued this write. Flush only replays entries matching the
  /// currently signed-in user so a shared tablet can't apply user A's queued
  /// writes as user B. Null = legacy entry written before this field existed.
  final String? userId;

  PendingMutation withIncrementedAttempt() => PendingMutation(
        id: id,
        kind: kind,
        payload: payload,
        createdAt: createdAt,
        attemptCount: attemptCount + 1,
        userId: userId,
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'kind': kind,
        'payload': payload,
        'created_at': createdAt.toIso8601String(),
        'attempt_count': attemptCount,
        if (userId != null) 'user_id': userId,
      };

  factory PendingMutation.fromJson(Map<String, dynamic> json) => PendingMutation(
        id: json['id'] as String,
        kind: json['kind'] as String,
        payload: Map<String, dynamic>.from(json['payload'] as Map),
        createdAt: DateTime.parse(json['created_at'] as String),
        attemptCount: json['attempt_count'] as int? ?? 0,
        userId: json['user_id'] as String?,
      );
}

/// What happened when a handler tried to apply a queued mutation.
enum MutationOutcome {
  /// Applied successfully; remove it from the queue.
  applied,

  /// Someone else changed the same record first (detected via an optimistic-concurrency
  /// check, e.g. an `updated_at` that no longer matches what the mutation was queued
  /// against). Per the migration plan's hard requirement, this must never be resolved by
  /// silently overwriting their change — it is removed from the retry queue and surfaced to
  /// the user instead (see `OfflineQueueController.conflicts`).
  conflict,

  /// A transient failure (still offline, a 5xx, a timeout). Stays in the queue and is
  /// retried on the next flush, up to [PendingMutation.attemptCount]'s caller-defined limit.
  retryableFailure,
}

class MutationResult {
  const MutationResult(this.outcome, {this.message});

  final MutationOutcome outcome;
  final String? message;
}

typedef MutationHandler = Future<MutationResult> Function(Map<String, dynamic> payload);
