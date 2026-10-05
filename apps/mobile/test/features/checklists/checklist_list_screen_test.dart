import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/features/checklists/application/checklists_providers.dart';
import 'package:venuewrangler_mobile/features/checklists/data/checklists_repository.dart';
import 'package:venuewrangler_mobile/features/checklists/domain/checklist_template.dart';
import 'package:venuewrangler_mobile/features/checklists/domain/item_result.dart';
import 'package:venuewrangler_mobile/features/checklists/presentation/checklist_list_screen.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

class _FakeChecklistsRepository implements ChecklistsRepository {
  _FakeChecklistsRepository(this.templates);

  final List<ChecklistTemplate> templates;

  @override
  Future<List<ChecklistTemplate>> fetchTemplatesForVenue(
    String venueId,
  ) async =>
      templates;

  @override
  Future<List<ChecklistTemplateItem>> fetchItemsForTemplate(
    String templateId,
  ) async =>
      const [];

  @override
  Future<void> submitCompletion({
    required String completionId,
    required String templateId,
    required List<ItemResult> itemResults,
    String? notes,
  }) async {}
}

void main() {
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue One',
    createdAt: DateTime(2026),
  );

  testWidgets('shows an empty state when the venue has no checklist templates',
      (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          checklistsRepositoryProvider
              .overrideWithValue(_FakeChecklistsRepository(const [])),
        ],
        child: const MaterialApp(home: ChecklistListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.textContaining('No checklists set up'), findsOneWidget);
  });

  testWidgets('lists checklist templates for the active venue', (tester) async {
    const template = ChecklistTemplate(
      id: 'template-1',
      venueId: 'venue-1',
      title: 'Opening checklist',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          activeVenueProvider.overrideWith((ref) => venue),
          checklistsRepositoryProvider
              .overrideWithValue(_FakeChecklistsRepository([template])),
        ],
        child: const MaterialApp(home: ChecklistListScreen()),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Opening checklist'), findsOneWidget);
  });
}
