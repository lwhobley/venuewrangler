import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/errors/transport_failure.dart';
import '../../../core/offline/offline_queue_providers.dart';
import '../../media/application/image_picker_service.dart';
import '../../media/application/media_providers.dart';
import '../../media/application/photo_annotator.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/domain/venue.dart';
import '../application/incidents_providers.dart';
import '../domain/incident.dart';
import '../../../core/privacy/screen_security.dart';

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
    final currentUserId = ref.watch(currentUserIdProvider);
    final draftTitlesById = {
      for (final mutation in queueState.pending)
        if (mutation.kind == kIncidentReportMutationKind &&
            mutation.userId == currentUserId &&
            mutation.payload['venueId'] == venue.id)
          mutation.payload['incidentId'] as String:
              mutation.payload['title'] as String,
    };

    return SecureScreen(
      child: Scaffold(
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
                      child:
                          const Center(child: Text('No incidents reported.')),
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
          onPressed: () => _showReportDialog(context, venue),
          icon: const Icon(Icons.report_outlined),
          label: const Text('Report incident'),
        ),
      ),
    );
  }

  Future<void> _showReportDialog(BuildContext context, Venue venue) =>
      showDialog<bool>(
        context: context,
        builder: (_) => _ReportIncidentDialog(venue: venue),
      );
}

/// The report form. It saves from inside the dialog and only closes once the report has been
/// filed (or queued offline): a missing title is flagged on the field, and a rejected save is
/// shown inline, so nothing the reporter typed is lost.
class _ReportIncidentDialog extends ConsumerStatefulWidget {
  const _ReportIncidentDialog({required this.venue});

  final Venue venue;

  @override
  ConsumerState<_ReportIncidentDialog> createState() =>
      _ReportIncidentDialogState();
}

class _ReportIncidentDialogState extends ConsumerState<_ReportIncidentDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  var _severity = IncidentSeverity.medium;
  String? _photoPath;
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    final description = _descriptionController.text.trim();
    final error = await _reportIncident(
      ScaffoldMessenger.of(context),
      ref,
      venue: widget.venue,
      title: _titleController.text.trim(),
      description: description.isEmpty ? null : description,
      severity: _severity,
      photoPath: _photoPath,
    );
    if (!mounted) return;
    if (error == null) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = error;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Report an incident'),
      content: SingleChildScrollView(
        child: Form(
          key: _formKey,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextFormField(
                controller: _titleController,
                autofocus: true,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(labelText: 'What happened?'),
                validator: (value) => (value ?? '').trim().isEmpty
                    ? 'Add a short summary of what happened.'
                    : null,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _descriptionController,
                decoration:
                    const InputDecoration(labelText: 'Details (optional)'),
                maxLines: 3,
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<IncidentSeverity>(
                initialValue: _severity,
                decoration: const InputDecoration(labelText: 'Severity'),
                items: [
                  for (final value in IncidentSeverity.values)
                    DropdownMenuItem(value: value, child: Text(value.name)),
                ],
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _severity = value ?? _severity),
              ),
              // Photo evidence is captured, annotated and uploaded by file path, which a browser
              // doesn't have (dart:io File/FileImage throw on web), so the option is native-only.
              if (!kIsWeb) const SizedBox(height: 12),
              if (!kIsWeb)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: _saving ? null : _pickPhoto,
                    icon: const Icon(Icons.camera_alt_outlined),
                    label: Text(
                      _photoPath == null ? 'Attach photo' : 'Photo attached',
                    ),
                  ),
                ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(color: theme.colorScheme.error),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Report'),
        ),
      ],
    );
  }

  Future<void> _pickPhoto() async {
    final picked = await ref
        .read(imagePickerServiceProvider)
        .pickImage(source: ImageSource.camera);
    if (picked == null || !mounted) return;
    // Let the reporter mark up the photo (circle the damage, add a label…)
    // before it's attached; backing out keeps the original.
    final annotate = ref.read(photoAnnotatorProvider);
    final annotated = await annotate(context, picked);
    if (!mounted) return;
    setState(() => _photoPath = annotated ?? picked);
  }

  /// Files the report, falling back to the offline queue on a transport failure. Returns null
  /// once the report is saved or queued, or a message to show in the form when it was rejected
  /// (the dialog then stays open with everything the reporter typed).
  Future<String?> _reportIncident(
    ScaffoldMessengerState messenger,
    WidgetRef ref, {
    required Venue venue,
    required String title,
    String? description,
    required IncidentSeverity severity,
    String? photoPath,
  }) async {
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
    } catch (error) {
      if (error is PostgrestException && error.code == '42501') {
        // The incident was never created; there is nothing to attach a photo to.
        return "You don't have permission to report incidents here.";
      }
      if (!isTransportFailure(error)) {
        // A deterministic rejection would never succeed on retry, so do not queue it.
        return "Couldn't report the incident. Please try again.";
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
      return null;
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
    return null;
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
    } catch (error) {
      if (error is PostgrestException && error.code == '42501') {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              "Incident reported, but you don't have permission to attach evidence to it.",
            ),
          ),
        );
        return;
      }
      if (!isTransportFailure(error)) {
        messenger.showSnackBar(
          const SnackBar(
            content: Text(
              'Incident reported, but the photo could not be attached. Please try again.',
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
      onTap: () => _showDetails(context, ref),
      trailing: incident.isOpen
          ? TextButton(
              onPressed: () => _resolve(context, ref),
              child: const Text('Resolve'),
            )
          : null,
    );
  }

  Future<void> _showDetails(BuildContext context, WidgetRef ref) async {
    final evidenceFuture =
        ref.read(incidentsRepositoryProvider).fetchEvidenceUrls(incident.id);
    // The dialog's FutureBuilder reports a failure; this only stops a failure that lands before
    // the dialog's first build from also surfacing as an unhandled error.
    unawaited(evidenceFuture.then((_) {}, onError: (_) {}));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(incident.title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('${incident.severity.name} · ${incident.status.name}'),
                if ((incident.description ?? '').trim().isNotEmpty) ...[
                  const SizedBox(height: 12),
                  Text(incident.description!),
                ],
                const SizedBox(height: 16),
                FutureBuilder<List<String>>(
                  future: evidenceFuture,
                  builder: (context, snapshot) {
                    if (snapshot.hasError) {
                      return const Text('Evidence could not be loaded.');
                    }
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    if (snapshot.data!.isEmpty) {
                      return const Text('No evidence attached.');
                    }
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Evidence'),
                        const SizedBox(height: 8),
                        for (final url in snapshot.data!)
                          Padding(
                            padding: const EdgeInsets.only(bottom: 8),
                            child: Image.network(
                              url,
                              errorBuilder: (_, __, ___) => const Text(
                                'This evidence image is unavailable.',
                              ),
                            ),
                          ),
                      ],
                    );
                  },
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
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
