import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/network/supabase_providers.dart';
import '../data/venues_repository.dart';
import '../domain/venue.dart';

final venuesRepositoryProvider = Provider<VenuesRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseVenuesRepository(client);
});

final venuesForOrganizationProvider =
    FutureProvider.family<List<Venue>, String>((ref, organizationId) {
  return ref
      .watch(venuesRepositoryProvider)
      .fetchVenuesForOrganization(organizationId);
});

/// The venue the user is currently acting within. `null` means "not chosen yet" and the
/// router sends them to the switcher screen. Deliberately in-memory only for this first
/// Phase 2 slice — persisting the last-selected venue (so returning users skip the switcher)
/// is a reasonable follow-up once core/storage's session-scoped persistence pattern is
/// established, but is not required for this slice to be correct or secure: RLS re-checks
/// venue membership on every query regardless of what the client remembers.
final activeVenueProvider = StateProvider<Venue?>((ref) => null);

const _managerRoles = {
  'venue_manager',
  'organization_owner',
  'organization_admin',
};

/// Whether the signed-in user holds a manager-tier role for the active venue — either a
/// venue_manager membership on it or an owner/admin membership on its organization. Used only
/// to decide what to *show*; the database enforces the same rule on every write.
final canManageActiveVenueProvider =
    FutureProvider.autoDispose<bool>((ref) async {
  final venue = ref.watch(activeVenueProvider);
  final userId = ref.watch(currentUserIdProvider);
  if (venue == null || userId == null) return false;
  final rows = await ref
      .watch(supabaseClientProvider)
      .from('memberships')
      .select('role, venue_id')
      .eq('user_id', userId)
      .eq('organization_id', venue.organizationId);
  return rows.any(
    (r) =>
        _managerRoles.contains(r['role']) &&
        (r['venue_id'] == null || r['venue_id'] == venue.id),
  );
});
