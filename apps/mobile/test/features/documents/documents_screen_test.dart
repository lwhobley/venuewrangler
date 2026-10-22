import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/errors/app_error.dart';
import 'package:venuewrangler_mobile/features/documents/application/document_picker_service.dart';
import 'package:venuewrangler_mobile/features/documents/application/documents_providers.dart';
import 'package:venuewrangler_mobile/features/documents/data/documents_repository.dart';
import 'package:venuewrangler_mobile/features/documents/domain/venue_document.dart';
import 'package:venuewrangler_mobile/features/documents/presentation/documents_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _Picker implements DocumentPickerService {
  @override
  Future<PickedDocument?> pickDocument() async => PickedDocument(
        bytes: Uint8List.fromList('menu'.codeUnits),
        name: 'menu.txt',
      );
}

class _Repo implements DocumentsRepository {
  Object? uploadError;
  String? uploadedTitle;

  @override
  Future<List<VenueDocument>> getDocuments({required String venueId}) async =>
      const [];

  @override
  Future<String> uploadDocument({
    required String venueId,
    required String title,
    required String category,
    required String fileName,
    String? localFilePath,
    Uint8List? bytes,
  }) async {
    if (uploadError != null) throw uploadError!;
    uploadedTitle = title;
    return 'doc-1';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue',
    createdAt: DateTime(2026),
  );

  Future<_Repo> openUploadDialog(WidgetTester tester) async {
    final repo = _Repo();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          currentUserIdProvider.overrideWithValue('user-1'),
          documentsRepositoryProvider.overrideWithValue(repo),
          documentPickerServiceProvider.overrideWithValue(_Picker()),
        ],
        child: const MaterialApp(home: DocumentsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Upload'));
    await tester.pumpAndSettle();
    return repo;
  }

  testWidgets('a blank title is flagged and the dialog stays open',
      (tester) async {
    final repo = await openUploadDialog(tester);

    await tester.enterText(find.widgetWithText(TextField, 'Title'), ' ');
    await tester.tap(find.widgetWithText(FilledButton, 'Upload'));
    await tester.pumpAndSettle();

    expect(find.text('Give the document a title.'), findsOneWidget);
    expect(find.text('Upload document'), findsOneWidget);
    expect(repo.uploadedTitle, isNull);
  });

  testWidgets('a failed upload shows why and keeps the details',
      (tester) async {
    final repo = await openUploadDialog(tester)
      ..uploadError = const PermissionDeniedError();

    await tester.enterText(
      find.widgetWithText(TextField, 'Title'),
      'Spring menu',
    );
    await tester.tap(find.widgetWithText(FilledButton, 'Upload'));
    await tester.pumpAndSettle();

    expect(find.text('You do not have access to do this.'), findsOneWidget);
    expect(find.text('Spring menu'), findsOneWidget);

    repo.uploadError = null;
    await tester.tap(find.widgetWithText(FilledButton, 'Upload'));
    await tester.pumpAndSettle();

    expect(repo.uploadedTitle, 'Spring menu');
    expect(find.text('Upload document'), findsNothing);
  });
}
