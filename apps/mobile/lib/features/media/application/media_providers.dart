import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_providers.dart';
import '../../../core/offline/pending_mutation.dart';
import '../data/media_repository.dart';

final mediaRepositoryProvider = Provider<MediaRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseMediaRepository(client);
});

/// Mutation kind for an incident-evidence photo queued while offline — the
/// "media-upload-retry metadata" item in the migration plan's offline-writable scope.
/// Payload: `attachmentId`/`incidentId`/`objectPath` (client-generated, for idempotent
/// retries) and `localFilePath` (where the picked image is cached on-device until uploaded).
///
/// Ordering note: when both an incident report and its evidence photo are queued offline in
/// the same session, the incident mutation is enqueued first (see
/// features/incidents/presentation/incident_list_screen.dart), so the queue's oldest-first
/// flush order guarantees the incident row exists before this mutation's attachment insert is
/// attempted — no extra coordination needed beyond enqueue order.
const String kIncidentEvidenceUploadMutationKind = 'incident_evidence_upload';

PendingMutation buildIncidentEvidenceUploadMutation({
  required String attachmentId,
  required String incidentId,
  required String objectPath,
  required String localFilePath,
  String? userId,
}) {
  return PendingMutation(
    id: attachmentId,
    kind: kIncidentEvidenceUploadMutationKind,
    createdAt: DateTime.now(),
    userId: userId,
    payload: {
      'attachmentId': attachmentId,
      'incidentId': incidentId,
      'objectPath': objectPath,
      'localFilePath': localFilePath,
    },
  );
}

final mediaMutationHandlersProvider = Provider<Map<String, MutationHandler>>((ref) {
  final repo = ref.watch(mediaRepositoryProvider);

  Future<MutationResult> handleEvidenceUpload(Map<String, dynamic> payload) async {
    try {
      await repo.uploadIncidentEvidence(
        attachmentId: payload['attachmentId'] as String,
        incidentId: payload['incidentId'] as String,
        objectPath: payload['objectPath'] as String,
        localFilePath: payload['localFilePath'] as String,
      );
      return const MutationResult(MutationOutcome.applied);
    } on LocalFileMissingException {
      return const MutationResult(
        MutationOutcome.conflict,
        message: 'The photo is no longer available on this device and could not be uploaded.',
      );
    } on PostgrestException catch (error) {
      if (error.code == '42501') {
        return const MutationResult(
          MutationOutcome.conflict,
          message: 'You no longer have permission to attach evidence to this incident.',
        );
      }
      rethrow; // network/5xx-shaped failures are retried by the queue controller.
    }
  }

  return {kIncidentEvidenceUploadMutationKind: handleEvidenceUpload};
});
