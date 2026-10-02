import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/integrations_repository.dart';
import '../domain/payroll_connection.dart';

final integrationsRepositoryProvider = Provider<IntegrationsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseIntegrationsRepository(client);
});

final payrollConnectionsForVenueProvider =
    FutureProvider.autoDispose.family<List<PayrollConnection>, String>((ref, venueId) {
  return ref.watch(integrationsRepositoryProvider).fetchConnectionsForVenue(venueId);
});
