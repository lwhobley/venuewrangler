import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/offline/offline_queue_providers.dart';
import '../../../core/offline/pending_mutation.dart';
import '../../venues/application/venues_providers.dart';
import '../application/incidents_providers.dart';
import '../domain/incident.dart';

const _uuid = Uuid();

/// Incident reports are offline-writable ("incident drafts" in the migration plan): see
/// `_reportIncident` below for the try-online-then-queue fallback, the same pattern used by
/// features/checklists for completion submission.
class IncidentListScreen extends ConsumerWidget {
  const IncidentListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final incidentsAsync = ref.watch(incidentsForVenueProvider(venue.id));
    final queueState = ref.watch(offlineQueueControllerProvider);
    final draftTitlesById = {
      for (final mutation in queueState.pending)
        if (mutation.kind == kIncidentReportMutationKind)
          mutation.payload['incidentId'] as String: mutation.payload['title'] as String,
    };

    return Scaffold(
      appBar: AppBar(title: Text('Incidents — ${venue.name}')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(incidentsForVenueProvider(venue.id)),
        child: incidentsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load incidents.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(incidentsForVenueProvider(venue.id)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (incidents) {
            final hasDrafts = draftTitlesById.isNotEmpty;
            if (incidents.isEmpty && !hasDrafts) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: const Center(child: Text('No incidents reported.')),
                  ),
                ),
              );
            }
            return ListView(
              children: [
                for (final title in draftTitlesById.values) _DraftTile(title: title),
                for (final incident in incidents)
                  _IncidentTile(incident: incident, venueId: venue.id),
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showReportDialog(context, ref, venue.id),
        icon: const Icon(Icons.report_outlined),
        label: const Text('Report incident'),
      ),
    );
  }

  Future<void> _showReportDialog(BuildContext context, WidgetRef ref, String venueId) async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    var severity = IncidentSeverity.medium;

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Report an incident'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'What happened?'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: descriptionController,
                decoration: const InputDecoration(labelText: 'Details (optional)'),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<IncidentSeverity>(
                value: severity,
                decoration: const InputDecoration(labelText: 'Severity'),
                items: [
                  for (final value in IncidentSeverity.values)
                    DropdownMenuItem(value: value, child: Text(value.name)),
                ],
                onChanged: (value) => setState(() => severity = value ?? severity),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Report'),
            ),
          ],
        ),
      ),
    );

    if (confirmed != true || titleController.text.trim().isEmpty || !context.mounted) return;

    await _reportIncident(
      context,
      ref,
      venueId: venueId,
      title: titleController.text.trim(),
      description:
          descriptionController.text.trim().isEmpty ? null : descriptionController.text.trim(),
      severity: severity,
    );
  }

  Future<void> _reportIncident(
    BuildContext context,
    WidgetRef ref, {
    required String venueId,
    required String title,
    String? description,
    required IncidentSeverity severity,
  }) async {
    final incidentId = _uuid.v4();

    try {
      await ref.read(incidentsRepositoryProvider).reportIncident(
            incidentId: incidentId,
            venueId: venueId,
            title: title,
            description: description,
            severity: severity,
          );
      ref.invalidate(incidentsForVenueProvider(venueId));
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        if (!context.mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text("You don't have permission to report incidents here.")),
        );
        return;
      }
      await _queueOffline(context, ref, incidentId, venueId, title, description, severity);
    } catch (_) {
      await _queueOffline(context, ref, incidentId, venueId, title, description, severity);
    }
  }

  Future<void> _queueOffline(
    BuildContext context,
    WidgetRef ref,
    String incidentId,
    String venueId,
    String title,
    String? description,
    IncidentSeverity severity,
  ) async {
    final mutation = buildIncidentReportMutation(
      incidentId: incidentId,
      venueId: venueId,
      title: title,
      description: description,
      severity: severity,
    );
    await ref.read(offlineQueueControllerProvider.notifier).enqueue(mutation);

    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text("Saved offline — this will sync once you're back online.")),
    );
  }
}

class _DraftTile extends StatelessWidget {
  const _DraftTile({required this.title});

  final String title;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: const Icon(Icons.sync, size: 20),
      title: Text(title),
      subtitle: const Text('Syncing…', style: TextStyle(fontStyle: FontStyle.italic)),
    );
  }
}

class _IncidentTile extends ConsumerWidget {
  const _IncidentTile({required this.incident, required this.venueId});

  final Incident incident;
  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(_iconForSeverity(incident.severity)),
      title: Text(incident.title),
      subtitle: Text('${incident.severity.name} · ${incident.status.name}'),
      trailing: incident.isOpen
          ? TextButton(
              onPressed: () => _resolve(context, ref),
              child: const Text('Resolve'),
            )
          : null,
    );
  }

  Future<void> _resolve(BuildContext context, WidgetRef ref) async {
    try {
      await ref
          .read(incidentsRepositoryProvider)
          .updateStatus(incident.id, IncidentStatus.resolved);
      ref.invalidate(incidentsForVenueProvider(venueId));
    } on PostgrestException catch (error) {
      if (!context.mounted) return;
      final message = error.code == '42501'
          ? "You don't have permission to resolve this incident."
          : 'Something went wrong. Please try again.';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  IconData _iconForSeverity(IncidentSeverity severity) => switch (severity) {
        IncidentSeverity.low => Icons.info_outline,
        IncidentSeverity.medium => Icons.warning_amber_outlined,
        IncidentSeverity.high => Icons.error_outline,
        IncidentSeverity.critical => Icons.dangerous_outlined,
      };
}
