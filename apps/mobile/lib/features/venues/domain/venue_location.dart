/// Input rules for a venue's time-clock location, matching `public.set_venue_location`
/// (supabase/migrations/20261022100000_venue_location_and_hours.sql).
library;

/// Geofence radii a manager can choose. The server accepts 50-1000 m: punches may report up to
/// 50 m GPS accuracy, so a smaller fence would refuse good fixes.
const kGeofenceRadiusOptions = [50, 75, 100, 150, 200, 300, 500, 1000];

/// Parses "41.8781, -87.6298" (the format map apps copy) into a coordinate pair, or null when
/// the text is not two numbers in range. (0, 0) is refused, as on the server.
({double latitude, double longitude})? parseCoordinates(String text) {
  final parts =
      text.trim().split(RegExp(r'[\s,;]+')).where((p) => p.isNotEmpty).toList();
  if (parts.length != 2) return null;
  final lat = double.tryParse(parts[0]);
  final lng = double.tryParse(parts[1]);
  if (lat == null || lng == null || !lat.isFinite || !lng.isFinite) {
    return null;
  }
  if (lat < -90 || lat > 90 || lng < -180 || lng > 180) return null;
  if (lat == 0 && lng == 0) return null;
  return (latitude: lat, longitude: lng);
}

/// "41.878100, -87.629800": six decimals is about 10 cm, more than GPS can tell.
String formatCoordinates(double latitude, double longitude) =>
    '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
