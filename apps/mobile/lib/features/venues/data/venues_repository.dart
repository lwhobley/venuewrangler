import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/venue.dart';

/// Same posture as OrganizationsRepository: the `venues_select_members` RLS policy already
/// restricts rows to venues the signed-in user can see, so this repository only needs to
/// scope the query to the chosen organization for UX, not for security.
abstract interface class VenuesRepository {
  Future<List<Venue>> fetchVenuesForOrganization(String organizationId);

  /// Sets where the venue is (`public.set_venue_location`: managers of the venue only,
  /// validated and audited server-side). Returns the updated venue.
  Future<Venue> setVenueLocation({
    required String venueId,
    required double latitude,
    required double longitude,
    required int geofenceRadiusM,
    String? address,
  });
}

class SupabaseVenuesRepository implements VenuesRepository {
  const SupabaseVenuesRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Venue>> fetchVenuesForOrganization(String organizationId) async {
    final rows = await _client
        .from('venues')
        .select()
        .eq('organization_id', organizationId)
        .order('name');

    return rows.map(Venue.fromJson).toList(growable: false);
  }

  @override
  Future<Venue> setVenueLocation({
    required String venueId,
    required double latitude,
    required double longitude,
    required int geofenceRadiusM,
    String? address,
  }) async {
    final row = await _client.rpc(
      'set_venue_location',
      params: {
        'p_venue_id': venueId,
        'p_latitude': latitude,
        'p_longitude': longitude,
        'p_geofence_radius_m': geofenceRadiusM,
        'p_address': address,
      },
    );
    return Venue.fromJson(Map<String, dynamic>.from(row as Map));
  }
}
