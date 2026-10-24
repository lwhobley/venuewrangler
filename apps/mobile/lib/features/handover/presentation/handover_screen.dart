import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/ops_colors.dart';
import '../../../core/widgets/state_views.dart';
import '../../ai/application/ai_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../application/handover_providers.dart';
import '../domain/handover_facts.dart';

/// End-of-shift handover for the next manager. The facts are gathered on the device from the
/// venue's own data ([HandoverFacts]); AI only writes them up, on request, into an editable
/// draft. Nothing is posted until the manager taps Post and confirms.
class HandoverScreen extends ConsumerStatefulWidget {
  const HandoverScreen({super.key});

  @override
  ConsumerState<HandoverScreen> createState() => _HandoverScreenState();
}

class _HandoverScreenState extends ConsumerState<HandoverScreen> {
  final _note = TextEditingController();
  HandoverFacts? _seededFrom;
  bool _edited = false;
  bool _aiDraft = false;
  bool _drafting = false;
  bool _posting = false;
  String? _aiError;
  String? _postError;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  /// Starts the editor from the deterministic note, and refreshes it when the facts reload
  /// unless the manager has started editing.
  void _seed(HandoverFacts facts, String venueName) {
    if (identical(_seededFrom, facts)) return;
    final first = _seededFrom == null;
    _seededFrom = facts;
    if (_edited || _aiDraft) return;
    final text = facts.toPlainText(venueName: venueName);
    if (first) {
      // The field is not built yet, so this is safe during build.
      _note.text = text;
      return;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_edited && !_aiDraft) {
        setState(() => _note.text = text);
      }
    });
  }

  Future<void> _draftWithAi(String venueId, HandoverFacts facts) async {
    if (_edited && !await _confirmReplace()) return;
    setState(() {
      _drafting = true;
      _aiError = null;
    });
    try {
      final result = await ref
          .read(aiRepositoryProvider)
          .summarizeHandover(venueId: venueId, facts: facts.toPromptJson());
      if (!mounted) return;
      if (result.isEmpty) {
        setState(() {
          _drafting = false;
          _aiError = 'The AI returned an empty note. Your facts list is below; '
              'edit the note by hand or try again.';
        });
        return;
      }
      _note.text = facts.resolvePeople(result.toText());
      setState(() {
        _drafting = false;
        _aiDraft = true;
        _edited = false;
      });
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() {
        _drafting = false;
        _aiError = error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _drafting = false;
        _aiError = 'Something went wrong. You can still edit the note by hand.';
      });
    }
  }

  Future<bool> _confirmReplace() async {
    final replace = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Replace your edits?'),
        content: const Text(
          'The AI draft will replace the text in the note.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep my text'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Replace'),
          ),
        ],
      ),
    );
    return replace == true;
  }

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: _note.text.trim()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Handover note copied.')),
    );
  }

  Future<void> _post(String venueId) async {
    final text = _note.text.trim();
    if (text.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Post to All Staff?'),
        content: const Text(
          'Everyone on the team can read this note in the All Staff chat. '
          'Check it first: remove anything not meant for the whole team.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Post'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() {
      _posting = true;
      _postError = null;
    });
    try {
      await postHandoverToAllStaff(ref, venueId: venueId, text: text);
      if (!mounted) return;
      setState(() => _posting = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Posted to All Staff.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _posting = false;
        _postError = error is StateError
            ? error.message
            : 'Could not post to team chat. Your note is still here; '
                'try again or copy it.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    final canManage = ref.watch(canManageActiveVenueProvider);
    final theme = Theme.of(context);

    Widget body;
    if (venue == null) {
      body = const Center(child: Text('No venue selected.'));
    } else if (canManage.isLoading) {
      body = const Center(child: CircularProgressIndicator());
    } else if (canManage.valueOrNull != true) {
      body = const EmptyState(
        icon: Icons.lock_outline,
        message: 'Shift handover is for managers.',
      );
    } else {
      final factsAsync = ref.watch(handoverFactsProvider);
      body = factsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => ErrorState(
          message: 'Could not gather tonight\'s facts.',
          onRetry: () => ref.invalidate(handoverFactsProvider),
        ),
        data: (facts) {
          _seed(facts, venue.name);
          return RefreshIndicator(
            onRefresh: () async {
              ref.invalidate(handoverFactsProvider);
              await ref.read(handoverFactsProvider.future);
            },
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                Text(
                  '${venue.name} · ${facts.dateLabel}',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Gathered from your venue data on this device, for the '
                  "venue's current business day.",
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                for (final section in facts.sections) ...[
                  _FactsCard(
                    title: section.title,
                    lines: section.lines,
                    unavailable: section.unavailable,
                  ),
                  const SizedBox(height: 8),
                ],
                const SizedBox(height: 12),
                _noteEditor(context, venue.id, facts),
              ],
            ),
          );
        },
      );
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Shift handover')),
      body: body,
    );
  }

  Widget _noteEditor(
    BuildContext context,
    String venueId,
    HandoverFacts facts,
  ) {
    final theme = Theme.of(context);
    final busy = _drafting || _posting;
    final hasText = _note.text.trim().isNotEmpty;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Handover note', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text(
          _aiDraft
              ? 'AI draft: check it against the facts above, then edit freely.'
              : 'Starts from the facts above. Edit it, or ask AI to write it up.',
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: _note,
          enabled: !_posting,
          minLines: 8,
          maxLines: 20,
          keyboardType: TextInputType.multiline,
          onChanged: (_) => setState(() => _edited = true),
          decoration:
              const InputDecoration(labelText: 'Note for the next manager'),
        ),
        if (_aiError != null) ...[
          const SizedBox(height: 8),
          Text(_aiError!, style: TextStyle(color: context.ops.danger.fg)),
        ],
        if (_postError != null) ...[
          const SizedBox(height: 8),
          Text(_postError!, style: TextStyle(color: context.ops.danger.fg)),
        ],
        const SizedBox(height: 12),
        FilledButton.tonalIcon(
          onPressed: busy ? null : () => _draftWithAi(venueId, facts),
          icon: _drafting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.auto_awesome),
          label: Text(_aiDraft ? 'Redraft with AI' : 'Write with AI'),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: busy || !hasText ? null : _copy,
                icon: const Icon(Icons.copy_outlined),
                label: const Text('Copy'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: busy || !hasText ? null : () => _post(venueId),
          icon: _posting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.send_outlined),
          label: const Text('Post to team chat (All Staff)'),
        ),
      ],
    );
  }
}

class _FactsCard extends StatelessWidget {
  const _FactsCard({
    required this.title,
    required this.lines,
    required this.unavailable,
  });

  final String title;
  final List<String> lines;
  final bool unavailable;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final muted = theme.colorScheme.onSurfaceVariant;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(AppRadii.tile),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: theme.textTheme.titleSmall),
            const SizedBox(height: 6),
            if (unavailable)
              Text(
                'Could not load this. Check it by hand.',
                style: TextStyle(color: context.ops.warning.fg),
              )
            else if (lines.isEmpty)
              Text('Nothing to report.', style: TextStyle(color: muted))
            else
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Text('• $line'),
                ),
          ],
        ),
      ),
    );
  }
}
