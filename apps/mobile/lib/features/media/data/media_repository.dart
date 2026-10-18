import 'dart:io';
import 'dart:typed_data';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../application/image_sanitizer.dart';

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
  /// `incident_attachments`. Idempotent for the same [attachmentId]/[objectPath]: the Storage
  /// upload treats an already-existing object as success (no upsert, since the bucket has no
  /// UPDATE policy) and the metadata insert (duplicate-key-is-success,
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

    // upsert: false on purpose. The incident-evidence bucket has no UPDATE policy (evidence is
    // immutable), and an upsert needs UPDATE, so a retry would fail with 403. A duplicate on a
    // retry means an earlier attempt already stored this object, which is success here.
    try {
      // Sanitized again at upload time: a photo queued by an older build may still carry GPS.
      final bytes = sanitizeImageBytes(await file.readAsBytes());
      await _client.storage.from('incident-evidence').uploadBinary(
            objectPath,
            bytes,
            fileOptions: FileOptions(
              upsert: false,
              contentType: _contentType(bytes),
            ),
          );
    } on StorageException catch (error) {
      if (!_isAlreadyUploaded(error)) rethrow;
    }

    try {
      await _client.from('incident_attachments').insert({
        'id': attachmentId,
        'incident_id': incidentId,
        'storage_path': objectPath,
      });
    } on PostgrestException catch (error) {
      if (error.code != '23505') rethrow;
      // 23505: already recorded by an earlier retry; done.
    }
    // The cached copy is no longer needed once the evidence is stored.
    await deleteTempImage(localFilePath);
  }

  String _contentType(Uint8List bytes) {
    if (bytes.length > 3 && bytes[0] == 0x89 && bytes[1] == 0x50) {
      return 'image/png';
    }
    if (bytes.length > 12 && bytes[0] == 0x52 && bytes[1] == 0x49) {
      return 'image/webp';
    }
    return 'image/jpeg';
  }

  /// Storage answers 409 / "Duplicate" when the object key already exists.
  bool _isAlreadyUploaded(StorageException error) {
    final code = error.statusCode;
    final name = error.error ?? '';
    return code == '409' ||
        name == 'Duplicate' ||
        error.message.toLowerCase().contains('already exists');
  }
}
