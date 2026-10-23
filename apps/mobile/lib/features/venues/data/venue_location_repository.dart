import 'package:supabase_flutter/supabase_flutter.dart';

class VenueLocationRepository {
  const VenueLocationRepository(this.client);
  final SupabaseClient client;
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
