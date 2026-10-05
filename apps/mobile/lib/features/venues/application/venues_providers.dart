import 'package:flutter_riverpod/flutter_riverpod.dart';

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
