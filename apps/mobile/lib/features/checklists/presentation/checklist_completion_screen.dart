import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/offline/offline_queue_providers.dart';
import '../application/checklists_providers.dart';
import '../domain/item_result.dart';

const _uuid = Uuid();

/// Submitting a completed checklist is offline-writable: a failed online submission is queued
/// (core/offline) and retried on reconnect, using a client-generated completion id so the
/// retry is idempotent (see ChecklistsRepository.submitCompletion) rather than risking a
/// duplicate submission.
class ChecklistCompletionScreen extends ConsumerStatefulWidget {
  const ChecklistCompletionScreen({super.key, required this.templateId, this.title});

  final String templateId;
  final String? title;

  @override
  ConsumerState<ChecklistCompletionScreen> createState() => _ChecklistCompletionScreenState();
}

class _ChecklistCompletionScreenState extends ConsumerState<ChecklistCompletionScreen> {
  final Map<String, bool> _checkedByItemId = {};
  bool _submitting = false;

  @override
  Widget build(BuildContext context) {
    final itemsAsync = ref.watch(checklistItemsForTemplateProvider(widget.templateId));

    return Scaffold(
      appBar: AppBar(title: Text(widget.title ?? 'Checklist')),
      body: itemsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Could not load this checklist.'),
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () =>
                    ref.invalidate(checklistItemsForTemplateProvider(widget.templateId)),
                child: const Text('Retry'),
              ),
            ],
          ),
        ),
        data: (items) {
          if (items.isEmpty) {
            return const Center(child: Text('This checklist has no items yet.'));
          }
          return ListView(
            children: [
              for (final item in items)
                CheckboxListTile(
                  title: Text(item.label),
                  value: _checkedByItemId[item.id] ?? false,
                  onChanged: (checked) {
                    setState(() => _checkedByItemId[item.id] = checked ?? false);
                  },
                ),
              Padding(
                padding: const EdgeInsets.all(16),
                child: FilledButton(
                  onPressed: _submitting ? null : () => _submit(items.map((i) => i.id)),
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Text('Submit'),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _submit(Iterable<String> itemIds) async {
    setState(() => _submitting = true);

    final completionId = _uuid.v4();
    final itemResults = [
      for (final itemId in itemIds)
        ItemResult(itemId: itemId, checked: _checkedByItemId[itemId] ?? false),
    ];

    try {
      await ref.read(checklistsRepositoryProvider).submitCompletion(
            completionId: completionId,
            templateId: widget.templateId,
            itemResults: itemResults,
          );
      if (!mounted) return;
      context.pop();
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        if (!mounted) return;
        setState(() => _submitting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You don't have permission to submit this checklist.")),
        );
        return;
      }
      await _queueOffline(completionId, itemResults);
    } catch (_) {
      await _queueOffline(completionId, itemResults);
    }
  }

  Future<void> _queueOffline(String completionId, List<ItemResult> itemResults) async {
    final mutation = buildChecklistCompletionMutation(
      completionId: completionId,
      templateId: widget.templateId,
      itemResults: itemResults,
    );
    await ref.read(offlineQueueControllerProvider.notifier).enqueue(mutation);

    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text("Saved offline — this will sync once you're back online."),
      ),
    );
    context.pop();
  }
}
