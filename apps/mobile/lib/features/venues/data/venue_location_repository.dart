import 'package:supabase_flutter/supabase_flutter.dart';

/// True when a venue row's coordinates form a usable geofence. Mirrors the server rule behind
/// `venue_geofence_required`: punches are refused while latitude or longitude is null, or
/// both are 0 (the "never set" placeholder).
bool venueHasGeofence(Object? latitude, Object? longitude) {
  if (latitude is! num || longitude is! num) return false;
  return !(latitude == 0 && longitude == 0);
}

class VenueLocationRepository {
  const VenueLocationRepository(this.client);
  final SupabaseClient client;

  /// Whether [venueId] has a clock-in geofence. Readable by the venue's managers.
  Future<bool> hasGeofence(String venueId) async {
    final row = await client
        .from('venues')
        .select('latitude, longitude')
        .eq('id', venueId)
        .maybeSingle();
    return venueHasGeofence(row?['latitude'], row?['longitude']);
  }

  Future<void> save(
    String venueId,
    String address,
    double lat,
    double lng,
    int radius,
  ) async {
    await client.rpc(
      'set_venue_location',
      params: {
        'p_venue_id': venueId,
        'p_address': address,
        'p_lat': lat,
        'p_lng': lng,
        'p_radius': radius,
      },
    );
  }
}
