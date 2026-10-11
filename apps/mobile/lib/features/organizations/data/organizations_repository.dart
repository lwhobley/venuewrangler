import 'package:supabase_flutter/supabase_flutter.dart';

import '../../venues/domain/venue.dart';
import '../domain/organization.dart';

/// UI depends on this interface, never on `SupabaseClient` directly. The Supabase
/// implementation does no authorization filtering itself — the
/// `organizations_select_members` RLS policy (supabase/migrations) already guarantees the
/// query only ever returns organizations the signed-in user is a member of (or every
/// organization, for a platform_admin). A modified client cannot widen this by changing the
/// query.
abstract interface class OrganizationsRepository {
  Future<List<Organization>> fetchMyOrganizations();

  /// Creates a brand-new organization + venue and makes the signed-in user its
  /// organization_owner, via `public.create_workspace` (supabase/migrations) — the only
  /// write path onto `organizations`/`memberships`, since neither table has a client-facing
  /// INSERT policy. Used by the sign-up flow's "Launch Workspace" path; see
  /// `features/organizations/application/organizations_providers.dart`'s
  /// `pendingWorkspaceCreationTriggerProvider`.
  Future<({Organization organization, Venue venue})> createWorkspace({
    required String organizationName,
    required String venueName,
    String timezone,
  });
}

class SupabaseOrganizationsRepository implements OrganizationsRepository {
  const SupabaseOrganizationsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Organization>> fetchMyOrganizations() async {
    final rows = await _client.from('organizations').select().order('name');

    return rows.map(Organization.fromJson).toList(growable: false);
  }

  @override
  Future<({Organization organization, Venue venue})> createWorkspace({
    required String organizationName,
    required String venueName,
    String timezone = 'UTC',
  }) async {
    final response = await _client.rpc(
      'create_workspace',
      params: {
        'p_organization_name': organizationName,
        'p_venue_name': venueName,
        'p_timezone': timezone,
      },
    );
    final row = (response as List<dynamic>).first as Map<String, dynamic>;
    // create_workspace does not return the zone it stored, so carry the requested one through
    // (normalized the same way the RPC does: trimmed, blank means UTC). Otherwise the venue
    // would silently report UTC.
    final storedTimezone = timezone.trim().isEmpty ? 'UTC' : timezone.trim();

    return (
      organization: Organization.fromJson({
        'id': row['organization_id'],
        'name': row['organization_name'],
        'created_at': row['organization_created_at'],
      }),
      venue: Venue.fromJson({
        'id': row['venue_id'],
        'organization_id': row['organization_id'],
        'name': row['venue_name'],
        'timezone': storedTimezone,
        'created_at': row['venue_created_at'],
      }),
    );
  }
}
