import '../../../core/widgets/home_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venues_providers.dart';
import '../application/document_picker_service.dart';
import '../application/documents_providers.dart';
import '../domain/venue_document.dart';

const _categoryLabels = {
  'sop': 'SOP',
  'manual': 'Manual',
  'recipe': 'Recipe',
  'menu': 'Menu',
  'training': 'Training',
  'form': 'Form',
  'other': 'Other',
};

/// Document creation/deletion rely entirely on RLS/the documents-upload Edge Function for
/// authorization (same "don't duplicate role checks client-side" convention as features/crm) —
/// a non-manager sees the same upload button as a manager, and gets a clear permission-denied
/// message if they try it, rather than this screen guessing their role up front.
class DocumentsScreen extends ConsumerWidget {
  const DocumentsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    final documentsAsync = ref.watch(documentsProvider(venue.id));

    return Scaffold(
      appBar: AppBar(
        leading: const HomeButton(),
        title: Text('Documents — ${venue.name}'),
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(documentsProvider(venue.id)),
        child: documentsAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text('Could not load documents.'),
                const SizedBox(height: 12),
                OutlinedButton(
                  onPressed: () => ref.invalidate(documentsProvider(venue.id)),
                  child: const Text('Retry'),
                ),
              ],
            ),
          ),
          data: (documents) {
            if (documents.isEmpty) {
              return LayoutBuilder(
                builder: (context, constraints) => SingleChildScrollView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  child: SizedBox(
                    height: constraints.maxHeight,
                    child: const Center(child: Text('No documents yet.')),
                  ),
                ),
              );
            }
            return ListView(
              children: [
                for (final document in documents)
                  _DocumentTile(document: document, venueId: venue.id),
              ],
            );
          },
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _upload(context, ref, venueId: venue.id),
        icon: const Icon(Icons.upload_file_outlined),
        label: const Text('Upload'),
      ),
    );
  }

  Future<void> _upload(
    BuildContext context,
    WidgetRef ref, {
    required String venueId,
  }) async {
    final picked = await ref.read(documentPickerServiceProvider).pickDocument();
    if (picked == null || !context.mounted) return;

    final titleController = TextEditingController(text: picked.name);
    var category = 'sop';

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Upload document'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: titleController,
                autofocus: true,
                decoration: const InputDecoration(labelText: 'Title'),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: category,
                decoration: const InputDecoration(labelText: 'Category'),
                items: [
                  for (final value in VenueDocument.categories)
                    DropdownMenuItem(
                      value: value,
                      child: Text(_categoryLabels[value] ?? value),
                    ),
                ],
                onChanged: (value) =>
                    setState(() => category = value ?? category),
              ),
              if (VenueDocument.managerOnlyCategories.contains(category)) ...[
                const SizedBox(height: 8),
                const Text(
                  'Only managers can see documents in this category.',
                  style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
                ),
              ],
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Upload'),
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

    try {
      await ref.read(documentsRepositoryProvider).uploadDocument(
            venueId: venueId,
            title: titleController.text.trim(),
            category: category,
            fileName: picked.name,
            localFilePath: picked.path,
          );
      ref.invalidate(documentsProvider(venueId));
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}

class _DocumentTile extends ConsumerWidget {
  const _DocumentTile({required this.document, required this.venueId});

  final VenueDocument document;
  final String venueId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return ListTile(
      leading: Icon(
        document.isManagerOnly
            ? Icons.lock_outline
            : Icons.description_outlined,
      ),
      title: Text(document.title),
      subtitle: Text(
        '${_categoryLabels[document.category] ?? document.category} · ${document.readableSize}',
      ),
      onTap: () => _open(context, ref),
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'Delete',
        onPressed: () => _delete(context, ref),
      ),
    );
  }

  Future<void> _open(BuildContext context, WidgetRef ref) async {
    try {
      final url = await ref
          .read(documentsRepositoryProvider)
          .getSignedUrl(storagePath: document.storagePath);
      await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }

  Future<void> _delete(BuildContext context, WidgetRef ref) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete document?'),
        content: Text('This removes "${document.title}" permanently.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;

    try {
      await ref
          .read(documentsRepositoryProvider)
          .deleteDocument(documentId: document.id);
      ref.invalidate(documentsProvider(venueId));
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
