import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/crm_repository.dart';
import '../domain/crm_beo.dart';
import '../domain/crm_contract.dart';
import '../domain/crm_lead.dart';

final crmRepositoryProvider = Provider<CrmRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseCrmRepository(client);
});

final crmLeadsProvider =
    FutureProvider.autoDispose.family<List<CrmLead>, String>((ref, venueId) {
  return ref.watch(crmRepositoryProvider).getLeads(venueId: venueId);
});

final crmNotesProvider =
    FutureProvider.autoDispose.family<List<CrmNote>, String>((ref, leadId) {
  return ref.watch(crmRepositoryProvider).getNotes(leadId: leadId);
});

final crmActivityProvider = FutureProvider.autoDispose
    .family<List<CrmActivityLogEntry>, String>((ref, leadId) {
  return ref.watch(crmRepositoryProvider).getActivity(leadId: leadId);
});

final crmBeosProvider =
    FutureProvider.autoDispose.family<List<CrmBeo>, String>((ref, venueId) {
  return ref.watch(crmRepositoryProvider).getBeos(venueId: venueId);
});

final crmContractsProvider = FutureProvider.autoDispose
    .family<List<CrmContract>, String>((ref, venueId) {
  return ref.watch(crmRepositoryProvider).getContracts(venueId: venueId);
});

final crmForecastProvider = FutureProvider.autoDispose
    .family<List<CrmForecastRow>, String>((ref, venueId) {
  return ref.watch(crmRepositoryProvider).getForecast(venueId: venueId);
});

final crmStaleLeadsProvider = FutureProvider.autoDispose
    .family<List<CrmStaleLead>, String>((ref, venueId) {
  return ref.watch(crmRepositoryProvider).getStaleLeads(venueId: venueId);
});
