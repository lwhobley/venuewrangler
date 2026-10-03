import 'dart:convert';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/errors/app_error.dart';
import '../domain/venue_document.dart';

/// Reads go straight through RLS (public.documents' category-aware select policy, see
/// supabase/migrations/20261003003000) — this repository does not duplicate that check. Writes
/// (upload) can only go through the documents-upload Edge Function: the table has no insert
/// policy for `authenticated` at all, since RLS cannot verify a ClamAV scan happened.
abstract interface class DocumentsRepository {
  Future<List<VenueDocument>> getDocuments({required String venueId});

  Future<String> uploadDocument({
    required String venueId,
    required String title,
    required String category,
    required String fileName,
    required String localFilePath,
  });

  Future<void> deleteDocument({required String documentId});

  /// Short-lived (120s) signed URL for viewing/downloading a document, via the staff-documents
  /// bucket's own category-aware select policy — direct policy-based access, same pattern as
  /// incident-evidence/checklist-evidence, not an Edge Function. Unlike legacy's presigned S3
  /// URL, this does not set a Content-Disposition override (see this feature's README for why)
  /// — the browser/OS picks inline-vs-download based on mime type on its own.
  Future<String> getSignedUrl({required String storagePath});
}

class SupabaseDocumentsRepository implements DocumentsRepository {
  const SupabaseDocumentsRepository(this._client);

  final SupabaseClient _client;

  @override
  Future<List<VenueDocument>> getDocuments({required String venueId}) async {
    try {
      final rows = await _client
          .from('documents')
          .select()
          .eq('venue_id', venueId)
          .order('created_at', ascending: false);
      return rows.map(VenueDocument.fromJson).toList(growable: false);
    } on PostgrestException {
      throw const NetworkError();
    }
  }

  @override
  Future<String> uploadDocument({
    required String venueId,
    required String title,
    required String category,
    required String fileName,
    required String localFilePath,
  }) async {
    final file = File(localFilePath);
    if (!await file.exists()) {
      throw const UnknownError('The selected file could not be found.');
    }
    final bytes = await file.readAsBytes();
    // 10MB cap matches documents-upload's own check; failing fast client-side avoids a
    // pointless base64-encoded multi-MB round trip when the file is already too large.
    const maxBytes = 10 * 1024 * 1024;
    if (bytes.length > maxBytes) {
      throw const UnknownError('That file is too large (max 10MB).');
    }

    try {
      final response = await _client.functions.invoke(
        'documents-upload',
        body: {
          'venue_id': venueId,
          'title': title,
          'file_name': fileName,
          // documents-upload trusts the magic-byte-detected MIME over this claim (see
          // _shared/document-bytes.ts); a generic value here is always accepted as a "claim",
          // never relied on for the actual stored mime_type.
          'mime_type': 'application/octet-stream',
          'category': category,
          'data_base64': base64Encode(bytes),
        },
      );
      final data = response.data;
      final id = (data is Map ? data['id'] : null) as String?;
      if (id == null) {
        throw const UnknownError('The document could not be uploaded. Please try again.');
      }
      return id;
    } on FunctionException catch (error) {
      throw _mapFunctionException(error);
    } on AppError {
      rethrow;
    } catch (_) {
      throw const NetworkError();
    }
  }

  @override
  Future<void> deleteDocument({required String documentId}) async {
    try {
      await _client.from('documents').delete().eq('id', documentId);
    } on PostgrestException {
      throw const NetworkError();
    }
  }

  @override
  Future<String> getSignedUrl({required String storagePath}) async {
    try {
      return await _client.storage.from('staff-documents').createSignedUrl(storagePath, 120);
    } on StorageException catch (error) {
      if (error.statusCode == '404') throw const NotFoundError('That document is no longer available.');
      throw const NetworkError();
    }
  }

  AppError _mapFunctionException(FunctionException error) {
    final details = error.details;
    final rawMessage = details is Map ? details['error'] as String? : null;

    if (error.status == 403) {
      return const PermissionDeniedError('Only venue managers can upload documents.');
    }
    if (error.status == 503) {
      // documents-upload returns 503 on a Storage upload failure (see its
      // document_storage_temporarily_unavailable error) — there is no malware-scanning step
      // to be unavailable any more (see that function's header comment on why it was removed).
      return const UnknownError('Document storage is temporarily unavailable. Please try again shortly.');
    }
    if (error.status == 400 && rawMessage != null) {
      // documents-upload's 400 bodies are already user-facing validation messages (e.g.
      // "Unsupported file type...", "Invalid PDF file.") — show them verbatim rather than
      // re-wording.
      return UnknownError(rawMessage);
    }
    if (rawMessage == 'invalid_or_expired_session') {
      return const AuthError('Your session has expired. Please sign in again.');
    }
    return const UnknownError('The document could not be uploaded. Please try again.');
  }
}
