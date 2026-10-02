import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/organizations_repository.dart';
import '../domain/organization.dart';

final organizationsRepositoryProvider = Provider<OrganizationsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseOrganizationsRepository(client);
});

final myOrganizationsProvider = FutureProvider<List<Organization>>((ref) {
  return ref.watch(organizationsRepositoryProvider).fetchMyOrganizations();
});
