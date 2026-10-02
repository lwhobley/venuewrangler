/// Time entry and break domain models for VenueWrangler.
///
/// Hand-written domain models representing clock punches, geofence fixes,
/// break intervals, and location anomaly audit markers.
library;

class TimeBreak {
  const TimeBreak({
    required this.type,
    required this.startAt,
    this.endAt,
  });

  final String type; // 'paid' | 'unpaid'
  final DateTime startAt;
  final DateTime? endAt;

  bool get isOpen => endAt == null;

  Duration get duration {
    final end = endAt ?? DateTime.now();
    return end.isAfter(startAt) ? end.difference(startAt) : Duration.zero;
  }

  factory TimeBreak.fromJson(Map<String, dynamic> json) => TimeBreak(
        type: json['type'] as String? ?? 'unpaid',
        startAt: DateTime.parse(json['start_at'] as String),
        endAt: json['end_at'] != null ? DateTime.parse(json['end_at'] as String) : null,
      );

  Map<String, dynamic> toJson() => {
        'type': type,
        'start_at': startAt.toIso8601String(),
        if (endAt != null) 'end_at': endAt!.toIso8601String(),
      };
}

class TimeEntry {
  const TimeEntry({
    required this.id,
    required this.organizationId,
    required this.venueId,
    required this.userId,
    this.shiftId,
    required this.clockInAt,
    required this.clockInLat,
    required this.clockInLng,
    required this.clockInAccuracyM,
    this.clockInMocked = false,
    this.clockOutAt,
    this.clockOutLat,
    this.clockOutLng,
    this.clockOutAccuracyM,
    this.clockOutMocked,
    required this.isOpen,
    this.breaks = const [],
    this.locationAnomaly,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;
  final String organizationId;
  final String venueId;
  final String userId;
  final String? shiftId;
  final DateTime clockInAt;
  final double clockInLat;
  final double clockInLng;
  final double clockInAccuracyM;
  final bool clockInMocked;
  final DateTime? clockOutAt;
  final double? clockOutLat;
  final double? clockOutLng;
  final double? clockOutAccuracyM;
  final bool? clockOutMocked;
  final bool isOpen;
  final List<TimeBreak> breaks;
  final String? locationAnomaly;
  final DateTime createdAt;
  final DateTime updatedAt;

  bool get isOnBreak => breaks.any((b) => b.isOpen);

  TimeBreak? get activeBreak => breaks.cast<TimeBreak?>().firstWhere(
        (b) => b != null && b.isOpen,
        orElse: () => null,
      );

  Duration get totalElapsed {
    final end = clockOutAt ?? DateTime.now();
    return end.isAfter(clockInAt) ? end.difference(clockInAt) : Duration.zero;
  }

  Duration get unpaidBreakDuration {
    var total = Duration.zero;
    for (final b in breaks) {
      if (b.type == 'unpaid') {
        total += b.duration;
      }
    }
    return total;
  }

  Duration get workedDuration {
    final raw = totalElapsed - unpaidBreakDuration;
    return raw.isNegative ? Duration.zero : raw;
  }

  factory TimeEntry.fromJson(Map<String, dynamic> json) {
    final rawBreaks = json['breaks'] as List<dynamic>? ?? const [];
    return TimeEntry(
      id: json['id'] as String,
      organizationId: json['organization_id'] as String,
      venueId: json['venue_id'] as String,
      userId: json['user_id'] as String,
      shiftId: json['shift_id'] as String?,
      clockInAt: DateTime.parse(json['clock_in_at'] as String),
      clockInLat: (json['clock_in_lat'] as num).toDouble(),
      clockInLng: (json['clock_in_lng'] as num).toDouble(),
      clockInAccuracyM: (json['clock_in_accuracy_m'] as num).toDouble(),
      clockInMocked: json['clock_in_mocked'] as bool? ?? false,
      clockOutAt: json['clock_out_at'] != null
          ? DateTime.parse(json['clock_out_at'] as String)
          : null,
      clockOutLat: (json['clock_out_lat'] as num?)?.toDouble(),
      clockOutLng: (json['clock_out_lng'] as num?)?.toDouble(),
      clockOutAccuracyM: (json['clock_out_accuracy_m'] as num?)?.toDouble(),
      clockOutMocked: json['clock_out_mocked'] as bool?,
      isOpen: json['is_open'] as bool? ?? false,
      breaks: rawBreaks
          .map((b) => TimeBreak.fromJson(b as Map<String, dynamic>))
          .toList(growable: false),
      locationAnomaly: json['location_anomaly'] as String?,
      createdAt: DateTime.parse(json['created_at'] as String),
      updatedAt: DateTime.parse(json['updated_at'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'organization_id': organizationId,
        'venue_id': venueId,
        'user_id': userId,
        if (shiftId != null) 'shift_id': shiftId,
        'clock_in_at': clockInAt.toIso8601String(),
        'clock_in_lat': clockInLat,
        'clock_in_lng': clockInLng,
        'clock_in_accuracy_m': clockInAccuracyM,
        'clock_in_mocked': clockInMocked,
        if (clockOutAt != null) 'clock_out_at': clockOutAt!.toIso8601String(),
        if (clockOutLat != null) 'clock_out_lat': clockOutLat,
        if (clockOutLng != null) 'clock_out_lng': clockOutLng,
        if (clockOutAccuracyM != null) 'clock_out_accuracy_m': clockOutAccuracyM,
        if (clockOutMocked != null) 'clock_out_mocked': clockOutMocked,
        'is_open': isOpen,
        'breaks': breaks.map((b) => b.toJson()).toList(),
        if (locationAnomaly != null) 'location_anomaly': locationAnomaly,
        'created_at': createdAt.toIso8601String(),
        'updated_at': updatedAt.toIso8601String(),
      };
}
