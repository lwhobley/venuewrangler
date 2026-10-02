import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Thrown by [MediaRepository.uploadIncidentEvidence] when the local file referenced by a
/// queued upload no longer exists (e.g. the OS reclaimed cache storage before the device
/// reconnected). This is not retryable — there is nothing left to upload — so callers should
/// treat it as a terminal failure (a conflict, in offline-queue terms), not queue it again.
class LocalFileMissingException implements Exception {
  const LocalFileMissingException(this.path);
  final String path;

  @override
  String toString() => 'LocalFileMissingException: $path no longer exists';
}

/// As with the other Phase 2/3 repositories, RLS is the actual authority (see
/// supabase/migrations/20261002040000_storage_buckets.sql and 20261002050000). This class
/// does not duplicate role checks.
abstract interface class MediaRepository {
  /// Uploads a local image file as evidence for [incidentId] and records its metadata in
  /// `incident_attachments`. Idempotent for the same [attachmentId]/[objectPath]: both the
  /// Storage upload (via `upsert: true`) and the metadata insert (duplicate-key-is-success,
  /// same pattern as ChecklistsRepository.submitCompletion) are safe to retry, which matters
  /// because this is exactly what the offline queue does on reconnect.
  Future<void> uploadIncidentEvidence({
    required String attachmentId,
    required String incidentId,
    required String objectPath,
    required String localFilePath,
  });
}

class SupabaseMediaRepository implements MediaRepository {
  const SupabaseMediaRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<void> uploadIncidentEvidence({
    required String attachmentId,
    required String incidentId,
    required String objectPath,
    required String localFilePath,
  }) async {
    final file = File(localFilePath);
    if (!await file.exists()) {
      throw LocalFileMissingException(localFilePath);
    }

    await _client.storage.from('incident-evidence').upload(
          objectPath,
          file,
          fileOptions: const FileOptions(upsert: true),
        );

    try {
      await _client.from('incident_attachments').insert({
        'id': attachmentId,
        'incident_id': incidentId,
        'storage_path': objectPath,
      });
    } on PostgrestException catch (error) {
      if (error.code == '23505') return; // already recorded by an earlier retry; done.
      rethrow;
    }
  }
}
