import 'dart:convert';

import '../../venues/domain/venue_clock.dart';

/// One booking in the way of a time, from the DETAIL of a `reservation_hold_conflict` error
/// (see app_hidden.reservation_hold_conflicts in
/// supabase/migrations/20261022130000_beo_cancel_restore_and_hold_sync.sql).
class HoldConflictItem {
  const HoldConflictItem({
    required this.isEvent,
    required this.name,
    required this.startsAt,
    this.partySize,
    this.endsAt,
  });

  /// A confirmed private event (its four-hour hold), rather than an ordinary reservation.
  final bool isEvent;
  final String name;
  final int? partySize;
  final DateTime startsAt;
  final DateTime? endsAt;
}

/// What a `reservation_hold_conflict` error says is in the way. [total] can exceed
/// [items].length: the server lists the first five.
class HoldConflict {
  const HoldConflict({required this.items, required this.total});

  final List<HoldConflictItem> items;
  final int total;

  bool get hasEvent => items.any((i) => i.isEvent);

  /// Parses the error's DETAIL. Returns an empty conflict (no names to show) when it is
  /// missing or malformed, e.g. from a server that predates the detail.
  static HoldConflict parse(Object? details) {
    try {
      final decoded = details is String ? jsonDecode(details) : details;
      if (decoded is! Map) return const HoldConflict(items: [], total: 0);
      final items = <HoldConflictItem>[
        for (final raw in (decoded['conflicts'] as List? ?? const []))
          if (raw is Map && raw['starts_at'] is String)
            HoldConflictItem(
              isEvent: raw['kind'] == 'event',
              name: (raw['name'] as String?)?.trim().isNotEmpty == true
                  ? raw['name'] as String
                  : 'Guest',
              partySize: (raw['party_size'] as num?)?.toInt(),
              startsAt: DateTime.parse(raw['starts_at'] as String).toUtc(),
              endsAt: raw['ends_at'] is String
                  ? DateTime.parse(raw['ends_at'] as String).toUtc()
                  : null,
            ),
      ];
      final total = (decoded['total'] as num?)?.toInt() ?? items.length;
      return HoldConflict(
        items: items,
        total: total < items.length ? items.length : total,
      );
    } on FormatException {
      return const HoldConflict(items: [], total: 0);
    } on TypeError {
      return const HoldConflict(items: [], total: 0);
    }
  }
}

/// Whether [message] (a Postgres error message) is a hold conflict.
bool isHoldConflictMessage(String message) =>
    message.contains('reservation_hold_conflict');

/// A sentence naming what blocks the time, in the venue's clock. [subject] is what was being
/// booked ("This event", "This time"). Falls back to a generic sentence when the server sent no
/// names, but never claims an event is in the way unless one is.
String describeHoldConflict(
  HoldConflict conflict,
  VenueClock clock, {
  required String subject,
}) {
  if (conflict.items.isEmpty) {
    return '$subject overlaps another booking. Choose another time.';
  }
  String describe(HoldConflictItem item) {
    final when = item.endsAt == null
        ? clock.formatTime(item.startsAt)
        : '${clock.formatTime(item.startsAt)}–${clock.formatTime(item.endsAt!)}';
    final party = item.partySize == null ? '' : ', ${item.partySize} guests';
    return item.isEvent
        ? 'the private event "${item.name}" ($when$party)'
        : '${item.name} at ${clock.formatTime(item.startsAt)}$party';
  }

  final events = conflict.items.where((i) => i.isEvent).toList();
  final reservations = conflict.items.where((i) => !i.isEvent).toList();
  final parts = <String>[
    if (events.isNotEmpty) events.map(describe).join(', '),
    if (reservations.isNotEmpty)
      '${reservations.length == 1 ? 'a reservation' : 'reservations'}: '
          '${reservations.map(describe).join('; ')}',
  ];
  final more = conflict.total - conflict.items.length;
  final tail = more > 0 ? ', and $more more' : '';
  final date = clock.formatDate(conflict.items.first.startsAt);
  final hold = events.isEmpty && subject == 'This event'
      ? ' A confirmed event holds the venue for four hours.'
      : '';
  return '$subject on $date overlaps ${parts.join(', and ')}$tail.$hold';
}
