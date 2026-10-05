import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../application/crm_providers.dart';
import '../domain/crm_lead.dart';

/// A lead's full record: notes (immutable once added) and the automatically-logged activity
/// trail (status changes, notes) — both written by DB triggers in crm_schema.sql, not by this
/// screen directly beyond the initial insert.
class CrmLeadDetailScreen extends ConsumerWidget {
  const CrmLeadDetailScreen({super.key, required this.lead});

  final CrmLead lead;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notesAsync = ref.watch(crmNotesProvider(lead.id));
    final activityAsync = ref.watch(crmActivityProvider(lead.id));

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: Text(lead.fullName),
          bottom:
              const TabBar(tabs: [Tab(text: 'Notes'), Tab(text: 'Activity')]),
        ),
        floatingActionButton: FloatingActionButton(
          onPressed: () => _showAddNoteDialog(context, ref),
          child: const Icon(Icons.add_comment_outlined),
        ),
        body: Column(
          children: [
            _LeadSummaryCard(lead: lead),
            Expanded(
              child: TabBarView(
                children: [
                  notesAsync.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, __) =>
                        const Center(child: Text('Could not load notes.')),
                    data: (notes) => notes.isEmpty
                        ? const Center(child: Text('No notes yet.'))
                        : ListView(
                            children: [
                              for (final note in notes)
                                ListTile(
                                  leading:
                                      const Icon(Icons.sticky_note_2_outlined),
                                  title: Text(note.text),
                                  subtitle:
                                      Text(_formatDateTime(note.createdAt)),
                                ),
                            ],
                          ),
                  ),
                  activityAsync.when(
                    loading: () =>
                        const Center(child: CircularProgressIndicator()),
                    error: (_, __) =>
                        const Center(child: Text('Could not load activity.')),
                    data: (activity) => activity.isEmpty
                        ? const Center(child: Text('No activity recorded yet.'))
                        : ListView(
                            children: [
                              for (final entry in activity)
                                ListTile(
                                  leading: Icon(_iconForKind(entry.kind)),
                                  title: Text(_labelForKind(entry.kind)),
                                  subtitle: Text(
                                    [
                                      if (entry.detail != null) entry.detail!,
                                      _formatDateTime(entry.createdAt),
                                    ].join(' · '),
                                  ),
                                ),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  IconData _iconForKind(String kind) => switch (kind) {
        'status_changed' => Icons.swap_horiz,
        'note_added' => Icons.sticky_note_2_outlined,
        'beo_status_changed' => Icons.event_note_outlined,
        _ => Icons.circle_outlined,
      };

  String _labelForKind(String kind) => switch (kind) {
        'status_changed' => 'Status changed',
        'note_added' => 'Note added',
        'beo_status_changed' => 'BEO status changed',
        _ => kind,
      };

  String _formatDateTime(DateTime dt) {
    final local = dt.toLocal();
    return '${local.year}-${local.month.toString().padLeft(2, '0')}-${local.day.toString().padLeft(2, '0')} '
        '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }

  Future<void> _showAddNoteDialog(BuildContext context, WidgetRef ref) async {
    final controller = TextEditingController();
    final text = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add note'),
        content:
            TextField(controller: controller, autofocus: true, maxLines: 4),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Add'),
          ),
        ],
      ),
    );

    if (text == null || text.isEmpty || !context.mounted) return;

    try {
      await ref
          .read(crmRepositoryProvider)
          .addNote(leadId: lead.id, text: text);
      ref.invalidate(crmNotesProvider(lead.id));
      ref.invalidate(crmActivityProvider(lead.id));
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not add note. Please try again.'),
          ),
        );
      }
    }
  }
}

class _LeadSummaryCard extends ConsumerWidget {
  const _LeadSummaryCard({required this.lead});

  final CrmLead lead;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Card(
      margin: const EdgeInsets.all(12),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (lead.company != null) Text(lead.company!),
                      if (lead.email != null) Text(lead.email!),
                      if (lead.phone != null) Text(lead.phone!),
                    ],
                  ),
                ),
                DropdownButton<String>(
                  value: lead.status,
                  items: [
                    for (final status in CrmLead.statuses)
                      DropdownMenuItem(value: status, child: Text(status)),
                  ],
                  onChanged: (value) async {
                    if (value == null || value == lead.status) return;
                    try {
                      await ref
                          .read(crmRepositoryProvider)
                          .updateLeadStatus(leadId: lead.id, status: value);
                      ref.invalidate(crmLeadsProvider(lead.venueId));
                      ref.invalidate(crmActivityProvider(lead.id));
                    } catch (_) {
                      if (context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('Could not update status.'),
                          ),
                        );
                      }
                    }
                  },
                ),
              ],
            ),
            if (lead.estimatedValueCents != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  'Estimated value: \$${(lead.estimatedValueCents! / 100).toStringAsFixed(2)}',
                ),
              ),
          ],
        ),
      ),
    );
  }
}
