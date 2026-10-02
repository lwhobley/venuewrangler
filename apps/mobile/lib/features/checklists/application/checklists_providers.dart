import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_providers.dart';
import '../../../core/offline/pending_mutation.dart';
import '../data/checklists_repository.dart';
import '../domain/checklist_template.dart';
import '../domain/item_result.dart';

final checklistsRepositoryProvider = Provider<ChecklistsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseChecklistsRepository(client);
});

final checklistTemplatesForVenueProvider =
    FutureProvider.autoDispose.family<List<ChecklistTemplate>, String>((ref, venueId) {
  return ref.watch(checklistsRepositoryProvider).fetchTemplatesForVenue(venueId);
});

final checklistItemsForTemplateProvider =
    FutureProvider.autoDispose.family<List<ChecklistTemplateItem>, String>((ref, templateId) {
  return ref.watch(checklistsRepositoryProvider).fetchItemsForTemplate(templateId);
});

/// Mutation kind for a checklist completion submitted while offline. Payload: `completionId`
/// (client-generated, carried through for idempotency — see
/// ChecklistsRepository.submitCompletion), `templateId`, `itemResults` (list of
/// ItemResult.toJson()), `notes`.
///
/// Unlike tasks' status-update mutation, this is an INSERT of a brand-new record, so there is
/// nothing to conflict with — the handler just retries until it succeeds (or is denied
/// outright, e.g. the user lost venue membership in the meantime, which surfaces as a
/// conflict since no retry would ever let it succeed).
const String kChecklistCompletionSubmitMutationKind = 'checklist_completion_submit';

PendingMutation buildChecklistCompletionMutation({
  required String completionId,
  required String templateId,
  required List<ItemResult> itemResults,
  String? notes,
}) {
  return PendingMutation(
    id: completionId,
    kind: kChecklistCompletionSubmitMutationKind,
    createdAt: DateTime.now(),
    payload: {
      'completionId': completionId,
      'templateId': templateId,
      'itemResults': itemResults.map((r) => r.toJson()).toList(),
      if (notes != null) 'notes': notes,
    },
  );
}

final checklistMutationHandlersProvider = Provider<Map<String, MutationHandler>>((ref) {
  final repo = ref.watch(checklistsRepositoryProvider);

  Future<MutationResult> handleCompletionSubmit(Map<String, dynamic> payload) async {
    final itemResultsJson = payload['itemResults'] as List<dynamic>;
    try {
      await repo.submitCompletion(
        completionId: payload['completionId'] as String,
        templateId: payload['templateId'] as String,
        itemResults: itemResultsJson
            .map((entry) => ItemResult.fromJson(entry as Map<String, dynamic>))
            .toList(),
        notes: payload['notes'] as String?,
      );
      return const MutationResult(MutationOutcome.applied);
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        return const MutationResult(
          MutationOutcome.conflict,
          message: "You no longer have permission to submit this checklist.",
        );
      }
      rethrow; // network/5xx-shaped failures are retried by the queue controller.
    }
  }

  return {kChecklistCompletionSubmitMutationKind: handleCompletionSubmit};
});
