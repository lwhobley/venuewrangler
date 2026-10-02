import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/venue.dart';

/// Same posture as OrganizationsRepository: the `venues_select_members` RLS policy already
/// restricts rows to venues the signed-in user can see, so this repository only needs to
/// scope the query to the chosen organization for UX, not for security.
abstract interface class VenuesRepository {
  Future<List<Venue>> fetchVenuesForOrganization(String organizationId);
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
}
