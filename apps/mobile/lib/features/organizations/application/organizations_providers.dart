import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/network/supabase_providers.dart';
import '../data/organizations_repository.dart';
import '../domain/organization.dart';

final organizationsRepositoryProvider =
    Provider<OrganizationsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseOrganizationsRepository(client);
});

final myOrganizationsProvider = FutureProvider<List<Organization>>((ref) {
  // Cached per signed-in user (see activeVenueProvider): organization names must not
  // survive a sign-out into the next person's session on the same device.
  ref.watch(currentUserIdProvider);
  return ref.watch(organizationsRepositoryProvider).fetchMyOrganizations();
});
