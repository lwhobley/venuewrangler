import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_providers.dart';
import '../../../core/network/supabase_providers.dart';
import '../data/documents_repository.dart';
import '../domain/venue_document.dart';

final documentsRepositoryProvider = Provider<DocumentsRepository>((ref) {
  return SupabaseDocumentsRepository(ref.watch(supabaseClientProvider));
});

final documentsProvider =
    FutureProvider.family<List<VenueDocument>, String>((ref, venueId) async {
  // Documents are manager-only data and this cache outlives screens: scope it to the
  // signed-in user so the next person on this device never sees the previous one's list.
  ref.watch(currentUserIdProvider);
  return ref.read(documentsRepositoryProvider).getDocuments(venueId: venueId);
});
