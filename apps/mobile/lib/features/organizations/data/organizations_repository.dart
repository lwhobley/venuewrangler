import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/organization.dart';

/// UI depends on this interface, never on `SupabaseClient` directly. The Supabase
/// implementation does no authorization filtering itself — the
/// `organizations_select_members` RLS policy (supabase/migrations) already guarantees the
/// query only ever returns organizations the signed-in user is a member of (or every
/// organization, for a platform_admin). A modified client cannot widen this by changing the
/// query.
abstract interface class OrganizationsRepository {
  Future<List<Organization>> fetchMyOrganizations();
}

class SupabaseOrganizationsRepository implements OrganizationsRepository {
  const SupabaseOrganizationsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<Organization>> fetchMyOrganizations() async {
    final rows = await _client.from('organizations').select().order('name');

    return rows.map(Organization.fromJson).toList(growable: false);
  }
}
