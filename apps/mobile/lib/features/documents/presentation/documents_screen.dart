import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venues_providers.dart';
import '../application/document_picker_service.dart';
import '../application/documents_providers.dart';
import '../domain/venue_document.dart';
import '../../../core/privacy/screen_security.dart';

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

    return SecureScreen(
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Documents'),
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
                    onPressed: () =>
                        ref.invalidate(documentsProvider(venue.id)),
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
    await showDialog<void>(
      context: context,
      builder: (_) => _UploadDocumentDialog(venueId: venueId, picked: picked),
    );
  }
}

/// Title/category for a picked file. Uploads from inside the dialog, which closes only once the
/// document is stored: a blank title is flagged on the field and a failed upload is shown in
/// place, so neither the picked file nor the typed details are lost.
class _UploadDocumentDialog extends ConsumerStatefulWidget {
  const _UploadDocumentDialog({required this.venueId, required this.picked});

  final String venueId;
  final PickedDocument picked;

  @override
  ConsumerState<_UploadDocumentDialog> createState() =>
      _UploadDocumentDialogState();
}

class _UploadDocumentDialogState extends ConsumerState<_UploadDocumentDialog> {
  final _formKey = GlobalKey<FormState>();
  late final _title = TextEditingController(text: widget.picked.name);
  var _category = 'sop';
  bool _saving = false;
  String? _error;

  @override
  void dispose() {
    _title.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    // Captured while mounted, so the list refreshes even if the screen closes mid-upload.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await ref.read(documentsRepositoryProvider).uploadDocument(
            venueId: widget.venueId,
            title: _title.text.trim(),
            category: _category,
            fileName: widget.picked.name,
            localFilePath: widget.picked.path,
            bytes: widget.picked.bytes,
          );
      container.invalidate(documentsProvider(widget.venueId));
      if (mounted) Navigator.of(context).pop();
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _saving = false;
        _error = error is AppError
            ? error.message
            : "Couldn't upload the document. Please try again.";
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Upload document'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextFormField(
              controller: _title,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Title'),
              validator: (value) => (value ?? '').trim().isEmpty
                  ? 'Give the document a title.'
                  : null,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: _category,
              decoration: const InputDecoration(labelText: 'Category'),
              items: [
                for (final value in VenueDocument.categories)
                  DropdownMenuItem(
                    value: value,
                    child: Text(_categoryLabels[value] ?? value),
                  ),
              ],
              onChanged: _saving
                  ? null
                  : (value) => setState(() => _category = value ?? _category),
            ),
            if (VenueDocument.managerOnlyCategories.contains(_category)) ...[
              const SizedBox(height: 8),
              Text(
                'Only managers can see documents in this category.',
                style: theme.textTheme.bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 12),
              Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _saving ? null : _submit,
          child: _saving
              ? const SizedBox.square(
                  dimension: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Upload'),
        ),
      ],
    );
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

    // Captured while mounted, so the list refreshes even if this screen closes mid-delete.
    final container = ProviderScope.containerOf(context, listen: false);
    try {
      await ref
          .read(documentsRepositoryProvider)
          .deleteDocument(documentId: document.id);
      container.invalidate(documentsProvider(venueId));
    } on AppError catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(error.message)));
    }
  }
}
