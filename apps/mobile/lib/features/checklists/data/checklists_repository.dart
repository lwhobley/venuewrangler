import 'package:supabase_flutter/supabase_flutter.dart';

import '../domain/checklist_template.dart';
import '../domain/item_result.dart';

/// As with the other Phase 2 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002020000_checklists_schema.sql) — this class does not duplicate
/// role checks.
abstract interface class ChecklistsRepository {
  Future<List<ChecklistTemplate>> fetchTemplatesForVenue(String venueId);

  Future<List<ChecklistTemplateItem>> fetchItemsForTemplate(String templateId);

  /// Idempotent: safe to call more than once with the same [completionId] (e.g. a retry from
  /// the offline queue after a connection dropped before the first attempt's response
  /// arrived). Deliberately NOT implemented as an upsert: `checklist_completions` only allows
  /// a manager to UPDATE an existing row (a completion is meant to be immutable to whoever
  /// submitted it — see the schema migration), so an upsert's conflict path would be denied
  /// for the common case of a staff member retrying their own submission. Instead, a plain
  /// insert that hits a duplicate key (the row already exists from an earlier attempt that
  /// actually succeeded) is treated as success rather than an error.
  Future<void> submitCompletion({
    required String completionId,
    required String templateId,
    required List<ItemResult> itemResults,
    String? notes,
  });
}

class SupabaseChecklistsRepository implements ChecklistsRepository {
  const SupabaseChecklistsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<ChecklistTemplate>> fetchTemplatesForVenue(String venueId) async {
    final rows = await _client
        .from('checklist_templates')
        .select()
        .eq('venue_id', venueId)
        .order('title');

    return rows.map(ChecklistTemplate.fromJson).toList(growable: false);
  }

  @override
  Future<List<ChecklistTemplateItem>> fetchItemsForTemplate(String templateId) async {
    final rows = await _client
        .from('checklist_template_items')
        .select()
        .eq('template_id', templateId)
        .order('position');

    return rows.map(ChecklistTemplateItem.fromJson).toList(growable: false);
  }

  @override
  Future<void> submitCompletion({
    required String completionId,
    required String templateId,
    required List<ItemResult> itemResults,
    String? notes,
  }) async {
    try {
      await _client.from('checklist_completions').insert({
        'id': completionId,
        'template_id': templateId,
        'item_results': itemResults.map((r) => r.toJson()).toList(),
        if (notes != null) 'notes': notes,
      });
    } on PostgrestException catch (error) {
      if (error.code == '23505') return; // already submitted by an earlier retry; done.
      rethrow;
    }
  }
}
