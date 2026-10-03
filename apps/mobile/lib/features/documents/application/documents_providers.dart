import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data/documents_repository.dart';
import '../domain/venue_document.dart';

final documentsRepositoryProvider = Provider<DocumentsRepository>((ref) {
  return SupabaseDocumentsRepository(Supabase.instance.client);
});

final documentsProvider =
    FutureProvider.family<List<VenueDocument>, String>((ref, venueId) async {
  return ref.read(documentsRepositoryProvider).getDocuments(venueId: venueId);
});
