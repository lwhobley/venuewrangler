import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/offline/offline_queue_providers.dart';
import '../../media/application/image_picker_service.dart';
import '../../media/application/media_providers.dart';
import '../../media/application/photo_annotator.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/domain/venue.dart';
import '../application/incidents_providers.dart';
import '../domain/incident.dart';

const _uuid = Uuid();

/// Incident reports are offline-writable ("incident drafts" in the migration plan): see
/// `_reportIncident` below for the try-online-then-queue fallback, the same pattern used by
/// features/checklists for completion submission. An optional evidence photo is handled the
/// same way via features/media (the "media-upload-retry metadata" item in the plan's offline
/// scope) — see `_attachPhotoIfPicked`, which runs only after the incident report itself has
/// either succeeded or been queued, since an attachment row can't exist before its incident
/// does (see the ordering note in media_providers.dart).
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
          mutation.payload['incidentId'] as String:
              mutation.payload['title'] as String,
    };

    return Scaffold(
      appBar: AppBar(
        title: const Text('Incidents'),
      ),
      body: RefreshIndicator(
        onRefresh: () async =>
            ref.invalidate(incidentsForVenueProvider(venue.id)),
        child: incidentsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load incidents.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () =>
                      ref.invalidate(incidentsForVenueProvider(venue.id)),
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
                for (final title in draftTitlesById.values)
                  _DraftTile(title: title),
                for (final incident in incidents)
                  _IncidentTile(incident: incident, venueId: venue.id),
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showReportDialog(context, ref, venue),
        icon: const Icon(Icons.report_outlined),
        label: const Text('Report incident'),
      ),
    );
  }

  Future<void> _showReportDialog(
    BuildContext context,
    WidgetRef ref,
    Venue venue,
  ) async {
    final titleController = TextEditingController();
    final descriptionController = TextEditingController();
    var severity = IncidentSeverity.medium;
    String? photoPath;

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
                decoration:
                    const InputDecoration(labelText: 'Details (optional)'),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<IncidentSeverity>(
                initialValue: severity,
                decoration: const InputDecoration(labelText: 'Severity'),
                items: [
                  for (final value in IncidentSeverity.values)
                    DropdownMenuItem(value: value, child: Text(value.name)),
                ],
                onChanged: (value) =>
                    setState(() => severity = value ?? severity),
              ),
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () async {
                    final picked = await ref
                        .read(imagePickerServiceProvider)
                        .pickImage(source: ImageSource.camera);
                    if (picked == null || !context.mounted) return;
                    // Let the reporter mark up the photo (circle the damage, add a label…)
                    // before it's attached; backing out keeps the original.
                    final annotated =
                        await ref.read(photoAnnotatorProvider)(context, picked);
                    setState(() => photoPath = annotated ?? picked);
                  },
                  icon: const Icon(Icons.camera_alt_outlined),
                  label: Text(
                    photoPath == null ? 'Attach photo' : 'Photo attached',
                  ),
                ),
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

    if (confirmed != true ||
        titleController.text.trim().isEmpty ||
        !context.mounted) {
      return;
    }

    await _reportIncident(
      context,
      ref,
      venue: venue,
      title: titleController.text.trim(),
      description: descriptionController.text.trim().isEmpty
          ? null
          : descriptionController.text.trim(),
      severity: severity,
      photoPath: photoPath,
    );
  }

  Future<void> _reportIncident(
    BuildContext context,
    WidgetRef ref, {
    required Venue venue,
    required String title,
    String? description,
    required IncidentSeverity severity,
    String? photoPath,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    final incidentId = _uuid.v4();

    try {
      await ref.read(incidentsRepositoryProvider).reportIncident(
            incidentId: incidentId,
            venueId: venue.id,
            title: title,
            description: description,
            severity: severity,
          );
      ref.invalidate(incidentsForVenueProvider(venue.id));
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        messenger.showSnackBar(
          const SnackBar(
            content:
                Text("You don't have permission to report incidents here."),
          ),
        );
        return; // the incident was never created; there is nothing to attach a photo to.
      }
      await _queueIncidentOffline(
        messenger,
        ref,
        incidentId,
        venue,
        title,
        description,
        severity,
      );
      if (photoPath != null) {
        await _attachPhotoOffline(
          ref,
          incidentId: incidentId,
          venue: venue,
          photoPath: photoPath,
        );
      }
      return;
    } catch (_) {
      await _queueIncidentOffline(
        messenger,
        ref,
        incidentId,
        venue,
        title,
        description,
        severity,
      );
      if (photoPath != null) {
        await _attachPhotoOffline(
          ref,
          incidentId: incidentId,
          venue: venue,
          photoPath: photoPath,
        );
      }
      return;
    }

    if (photoPath != null) {
      await _attachPhoto(
        messenger,
        ref,
        incidentId: incidentId,
        venue: venue,
        photoPath: photoPath,
      );
    }
  }

  Future<void> _attachPhoto(
    ScaffoldMessengerState messenger,
    WidgetRef ref, {
    required String incidentId,
    required Venue venue,
    required String photoPath,
  }) async {
    final attachmentId = _uuid.v4();
    final extension =
        photoPath.contains('.') ? photoPath.split('.').last : 'jpg';
    final objectPath =
        '${venue.organizationId}/${venue.id}/$attachmentId.$extension';

    try {
      await ref.read(mediaRepositoryProvider).uploadIncidentEvidence(
            attachmentId: attachmentId,
            incidentId: incidentId,
            objectPath: objectPath,
            localFilePath: photoPath,
          );
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              "Incident reported, but you don't have permission to attach evidence to it.",
            ),
          ),
        );
        return;
      }
      await _attachPhotoOffline(
        ref,
        incidentId: incidentId,
        venue: venue,
        photoPath: photoPath,
        attachmentId: attachmentId,
        objectPath: objectPath,
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "Incident reported. The photo will upload once you're back online.",
          ),
        ),
      );
    } catch (_) {
      await _attachPhotoOffline(
        ref,
        incidentId: incidentId,
        venue: venue,
        photoPath: photoPath,
        attachmentId: attachmentId,
        objectPath: objectPath,
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text(
            "Incident reported. The photo will upload once you're back online.",
          ),
        ),
      );
    }
  }

  Future<void> _attachPhotoOffline(
    WidgetRef ref, {
    required String incidentId,
    required Venue venue,
    required String photoPath,
    String? attachmentId,
    String? objectPath,
  }) async {
    final resolvedAttachmentId = attachmentId ?? _uuid.v4();
    final extension =
        photoPath.contains('.') ? photoPath.split('.').last : 'jpg';
    final resolvedObjectPath = objectPath ??
        '${venue.organizationId}/${venue.id}/$resolvedAttachmentId.$extension';

    final mutation = buildIncidentEvidenceUploadMutation(
      attachmentId: resolvedAttachmentId,
      incidentId: incidentId,
      objectPath: resolvedObjectPath,
      localFilePath: photoPath,
    );
    await ref.read(offlineQueueControllerProvider.notifier).enqueue(mutation);
  }

  Future<void> _queueIncidentOffline(
    ScaffoldMessengerState messenger,
    WidgetRef ref,
    String incidentId,
    Venue venue,
    String title,
    String? description,
    IncidentSeverity severity,
  ) async {
    final mutation = buildIncidentReportMutation(
      incidentId: incidentId,
      venueId: venue.id,
      title: title,
      description: description,
      severity: severity,
    );
    await ref.read(offlineQueueControllerProvider.notifier).enqueue(mutation);

    messenger.showSnackBar(
      const SnackBar(
        content:
            Text("Saved offline — this will sync once you're back online."),
      ),
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
      subtitle:
          const Text('Syncing…', style: TextStyle(fontStyle: FontStyle.italic)),
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
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  IconData _iconForSeverity(IncidentSeverity severity) => switch (severity) {
        IncidentSeverity.low => Icons.info_outline,
        IncidentSeverity.medium => Icons.warning_amber_outlined,
        IncidentSeverity.high => Icons.error_outline,
        IncidentSeverity.critical => Icons.dangerous_outlined,
      };
}
