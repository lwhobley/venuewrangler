import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../../core/auth/auth_providers.dart';
import '../../ai/application/ai_providers.dart';
import '../../ai/domain/ai_models.dart';
import '../application/inventory_providers.dart';
import '../domain/inventory_v2.dart';
import 'inventory_widgets.dart';

class InventoryImportScreen extends ConsumerStatefulWidget {
  const InventoryImportScreen({super.key, required this.scope});

  final InventoryScope scope;

  @override
  ConsumerState<InventoryImportScreen> createState() => _ImportState();
}

class _ImportState extends ConsumerState<InventoryImportScreen> {
  final input = TextEditingController();
  List<InventoryLineItem>? lines;
  bool busy = false;
  String? error;
  final applied = <int>{};
  String mode = 'RECEIVE';
  late final String? userId;

  @override
  void initState() {
    super.initState();
    userId = ref.read(currentUserIdProvider);
  }

  @override
  void dispose() {
    input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot =
        ref.watch(inventorySnapshotProvider(widget.scope)).valueOrNull;
    return Scaffold(
      appBar: AppBar(title: const Text('Review inventory import')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(
            'Invoice or count sheet',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
          const SizedBox(height: 8),
          const Text(
            'Paste copied text or upload a TXT/CSV file. AI suggestions change no inventory until you review and confirm a line.',
          ),
          const SizedBox(height: 16),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                value: 'RECEIVE',
                label: Text('Receive delivery'),
              ),
              ButtonSegment(value: 'COUNT', label: Text('Count sheet')),
            ],
            selected: {mode},
            onSelectionChanged: applied.isNotEmpty
                ? null
                : (v) => setState(() => mode = v.single),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: input,
            maxLines: 8,
            decoration: const InputDecoration(
              labelText: 'Invoice or inventory text',
              alignLabelWithHint: true,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 12,
            children: [
              OutlinedButton.icon(
                onPressed: busy || applied.isNotEmpty ? null : _upload,
                icon: const Icon(Icons.upload_file_outlined),
                label: const Text('Upload text'),
              ),
              FilledButton(
                onPressed: busy || applied.isNotEmpty ? null : _parse,
                child: Text(busy ? 'Parsing…' : 'Parse for review'),
              ),
            ],
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                error!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          if (lines != null && snapshot != null) ...[
            inventoryHeading(context, 'Review ${lines!.length} lines'),
            for (var index = 0; index < lines!.length; index++)
              _preview(snapshot, index),
            if (lines!.isEmpty)
              const InventoryEmpty(
                'No items could be parsed. Add items manually or try clearer text.',
              ),
          ],
          if (applied.isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 16),
              child: Text(
                'Confirmed lines are recorded. Start a new import after leaving this screen.',
              ),
            ),
        ],
      ),
    );
  }

  Widget _preview(InventorySnapshot s, int index) {
    final line = lines![index];
    final match = matchInventoryItem(line.name, s.items);
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(vertical: 8),
      title: Text(line.name),
      subtitle: Text(
        '${line.quantity ?? '?'} ${line.unit ?? 'unit unknown'}${line.sizeAmount == null ? '' : ' • ${line.sizeAmount} ${line.sizeUnit ?? ''}'}\n${match.label}${match.item == null ? '' : ' (${match.item!.name})'}',
      ),
      trailing: applied.contains(index)
          ? const Icon(Icons.check_circle_outline)
          : TextButton(
              onPressed: () => _review(line, index),
              child: const Text('Review'),
            ),
    );
  }

  Future<void> _upload() async {
    try {
      final picked = await FilePicker.instance.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['txt', 'csv'],
        withData: true,
      );
      final file = picked?.files.single;
      if (file == null) return;
      if (file.size > 2 * 1024 * 1024) {
        throw const FormatException('Upload text smaller than 2 MB.');
      }
      if (file.bytes == null) {
        throw const FormatException(
          'Could not read this file. Paste its text instead.',
        );
      }

      String decoded;
      try {
        decoded = utf8.decode(file.bytes!);
      } on FormatException {
        decoded = latin1.decode(file.bytes!);
        if (decoded.runes.any((r) => r >= 0x80 && r <= 0x9f)) {
          throw const FormatException(
            'This file uses an unsupported text encoding. Export it as UTF-8 CSV and try again.',
          );
        }
      }

      if (decoded.trim().length > 20000) {
        throw const FormatException(
          'This import is too long for AI parsing. Use a file under 20,000 characters or split it into smaller parts.',
        );
      }

      input.text = decoded;
      if (mounted) setState(() => error = null);
    } catch (e) {
      if (mounted) setState(() => error = inventoryError(e));
    }
  }

  Future<void> _parse() async {
    final text = input.text.trim();
    if (text.isEmpty) {
      setState(() => error = 'Paste text or upload a text file first.');
      return;
    }
    if (text.length > 20000) {
      setState(() {
        error = 'AI parsing accepts up to 20,000 characters. '
            'Split the import into smaller parts.';
      });
      return;
    }

    setState(() {
      busy = true;
      error = null;
    });

    try {
      assertInventoryScope(ref, widget.scope, userId);
      final result = await ref.read(aiRepositoryProvider).parseInventory(
        venueId: widget.scope.venueId,
        pastedText: text,
      );
      if (mounted) setState(() => lines = result.items);
    } catch (e) {
      if (mounted) setState(() => error = inventoryError(e));
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _review(InventoryLineItem line, int index) async {
    final result = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (_) => _ImportReview(
          scope: widget.scope,
          line: line,
          action: mode,
        ),
      ),
    );
    if (result == true && mounted) {
      setState(() => applied.add(index));
    }
  }
}

class _ImportReview extends ConsumerStatefulWidget {
  const _ImportReview({
    required this.scope,
    required this.line,
    required this.action,
  });

  final InventoryScope scope;
  final InventoryLineItem line;
  final String action;

  @override
  ConsumerState<_ImportReview> createState() => _ReviewState();
}

class _ReviewState extends ConsumerState<_ImportReview> {
  final form = GlobalKey<FormState>();
  late final quantity =
      TextEditingController(text: widget.line.quantity?.toString());
  final notes = TextEditingController();
  late final String? userId;
  final operationId = const Uuid().v4();
  String? itemId, stockId, error;
  bool initialized = false, busy = false, verified = false;

  @override
  void initState() {
    super.initState();
    userId = ref.read(currentUserIdProvider);
  }

  @override
  void dispose() {
    quantity.dispose();
    notes.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Confirm parsed line')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Form(
          key: form,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(widget.line.name),
              const SizedBox(height: 16),
              TextFormField(
                controller: quantity,
                decoration: const InputDecoration(labelText: 'Quantity'),
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: notes,
                maxLines: 4,
                decoration: const InputDecoration(labelText: 'Notes'),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Confirm'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
