import 'dart:math' as math;

/// Client-side Geofence calculator matching PostgreSQL `app_hidden.haversine_distance_m`.
class GeofenceHelper {
  const GeofenceHelper._();

  static const double earthRadiusM = 6371000.0;

  /// Returns distance in metres between two coordinate pairs using Haversine formula.
  static double calculateDistanceM({
    required double lat1,
    required double lng1,
    required double lat2,
    required double lng2,
  }) {
    final dLat = _toRadians(lat2 - lat1);
    final dLng = _toRadians(lng2 - lng1);
    final a = math.pow(math.sin(dLat / 2.0), 2) +
        math.cos(_toRadians(lat1)) *
            math.cos(_toRadians(lat2)) *
            math.pow(math.sin(dLng / 2.0), 2);
    final clampedA = math.min(1.0, math.max(0.0, a.toDouble()));
    return 2.0 * earthRadiusM * math.asin(math.sqrt(clampedA));
  }

  static double _toRadians(double degrees) => degrees * (math.pi / 180.0);
}
