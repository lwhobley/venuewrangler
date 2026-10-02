import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/offline/pending_mutation.dart';
import 'package:venuewrangler_mobile/features/media/application/media_providers.dart';
import 'package:venuewrangler_mobile/features/media/data/media_repository.dart';

class _FakeMediaRepository implements MediaRepository {
  Exception? throwOnUpload;
  bool uploaded = false;

  @override
  Future<void> uploadIncidentEvidence({
    required String attachmentId,
    required String incidentId,
    required String objectPath,
    required String localFilePath,
  }) async {
    if (throwOnUpload != null) throw throwOnUpload!;
    uploaded = true;
  }
}

Map<String, dynamic> _payload() => {
      'attachmentId': 'attachment-1',
      'incidentId': 'incident-1',
      'objectPath': 'org-1/venue-1/attachment-1.jpg',
      'localFilePath': '/tmp/photo.jpg',
    };

void main() {
  test('a successful upload is reported as applied', () async {
    final fakeRepo = _FakeMediaRepository();
    final container = ProviderContainer(
      overrides: [mediaRepositoryProvider.overrideWithValue(fakeRepo)],
    );
    addTearDown(container.dispose);

    final handler =
        container.read(mediaMutationHandlersProvider)[kIncidentEvidenceUploadMutationKind]!;
    final result = await handler(_payload());

    expect(result.outcome, MutationOutcome.applied);
    expect(fakeRepo.uploaded, isTrue);
  });

  test('a missing local file is reported as a non-retryable conflict', () async {
    final fakeRepo = _FakeMediaRepository()
      ..throwOnUpload = const LocalFileMissingException('/tmp/photo.jpg');
    final container = ProviderContainer(
      overrides: [mediaRepositoryProvider.overrideWithValue(fakeRepo)],
    );
    addTearDown(container.dispose);

    final handler =
        container.read(mediaMutationHandlersProvider)[kIncidentEvidenceUploadMutationKind]!;
    final result = await handler(_payload());

    expect(result.outcome, MutationOutcome.conflict);
  });

  test('a permission-denied failure is reported as a conflict, not retried', () async {
    final fakeRepo = _FakeMediaRepository()
      ..throwOnUpload = PostgrestException(message: 'denied', code: '42501');
    final container = ProviderContainer(
      overrides: [mediaRepositoryProvider.overrideWithValue(fakeRepo)],
    );
    addTearDown(container.dispose);

    final handler =
        container.read(mediaMutationHandlersProvider)[kIncidentEvidenceUploadMutationKind]!;
    final result = await handler(_payload());

    expect(result.outcome, MutationOutcome.conflict);
  });

  test('a network-shaped failure propagates so the queue controller retries it', () async {
    final fakeRepo = _FakeMediaRepository()..throwOnUpload = Exception('network unreachable');
    final container = ProviderContainer(
      overrides: [mediaRepositoryProvider.overrideWithValue(fakeRepo)],
    );
    addTearDown(container.dispose);

    final handler =
        container.read(mediaMutationHandlersProvider)[kIncidentEvidenceUploadMutationKind]!;

    expect(() => handler(_payload()), throwsException);
  });
}
