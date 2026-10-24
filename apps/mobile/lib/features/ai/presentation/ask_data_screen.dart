import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_error.dart';
import '../../../core/theme/app_radii.dart';
import '../../../core/theme/ops_colors.dart';
import '../../venues/application/venue_clock.dart';
import '../../venues/application/venues_providers.dart';
import '../application/ask_data_providers.dart';
import '../application/ask_data_service.dart';
import '../application/quick_numbers.dart';
import '../domain/data_catalogue.dart';

const _examples = <String>[
  'How many covers did we do last Friday?',
  "What's our no-show rate this month?",
  'Who worked the most hours last week?',
  'How much did private events bring in in October?',
];

const _maxQuestionChars = 400;

/// "Ask about your data": a manager asks a question in plain words and gets a short answer
/// worked out from fixed, read-only reports for this venue. The AI only picks reports and words
/// the answer; every figure comes from the aggregate rows shown under "How I got this". Nothing
/// is saved: the question lives in this screen only. The "Quick numbers" list works without AI.
class AskDataScreen extends ConsumerStatefulWidget {
  const AskDataScreen({super.key});

  @override
  ConsumerState<AskDataScreen> createState() => _AskDataScreenState();
}

class _AskDataScreenState extends ConsumerState<AskDataScreen> {
  final _questionController = TextEditingController();
  bool _isAsking = false;
  AskDataOutcome? _outcome;
  AppError? _error;

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    final canManage = ref.watch(canManageActiveVenueProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Ask about your data')),
      body: venue == null
          ? const Center(child: Text('No venue selected.'))
          : canManage.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Center(
                child: Text('Could not check your access. Try again.'),
              ),
              data: (allowed) => !allowed
                  ? const Center(
                      child: Padding(
                        padding: EdgeInsets.all(24),
                        child: Text(
                          'Only managers of this venue can ask about its data.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : _body(context, venue.id),
            ),
    );
  }

  Widget _body(BuildContext context, String venueId) {
    final theme = Theme.of(context);
    final outcome = _outcome;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Text(
          'Ask about reservations, hours, shifts, events, incidents, stock, tasks '
          'or sales. Answers come from fixed, read-only reports for this venue, '
          'and you can check them under "How I got this".',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 12),
        TextField(
          controller: _questionController,
          maxLines: 3,
          minLines: 2,
          maxLength: _maxQuestionChars,
          textInputAction: TextInputAction.newline,
          decoration: const InputDecoration(labelText: 'Your question'),
        ),
        const SizedBox(height: 4),
        Wrap(
          spacing: 8,
          runSpacing: 4,
          children: [
            for (final example in _examples)
              ActionChip(
                label: Text(example),
                onPressed: _isAsking
                    ? null
                    : () => setState(() {
                          _questionController.text = example;
                          _questionController.selection =
                              TextSelection.collapsed(
                            offset: example.length,
                          );
                        }),
              ),
          ],
        ),
        const SizedBox(height: 12),
        FilledButton.icon(
          onPressed: _isAsking ? null : () => _ask(venueId),
          icon: _isAsking
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.query_stats_outlined),
          label: Text(_isAsking ? 'Looking it up...' : 'Ask'),
        ),
        const SizedBox(height: 8),
        Text(
          'Sent to the AI provider: your question and summary figures from the '
          'reports (counts, totals and, for hours questions, staff names). Never '
          'pay rates, contact details, notes or raw records.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 16),
        if (_error != null) _MessageCard.error(message: _error!.message),
        if (outcome is AskDataAnswered) ...[
          _AnswerCard(outcome: outcome),
          const SizedBox(height: 12),
          _HowIGotThis(outcome: outcome),
        ],
        if (outcome is AskDataUnanswerable) _UnanswerableCard(outcome: outcome),
        const SizedBox(height: 24),
        const _QuickNumbersSection(),
      ],
    );
  }

  Future<void> _ask(String venueId) async {
    final question = _questionController.text.trim();
    if (question.isEmpty) return;
    final today = ref.read(venueClockProvider).now;

    setState(() {
      _isAsking = true;
      _error = null;
      _outcome = null;
    });
    try {
      final outcome = await ref
          .read(askDataServiceProvider)
          .ask(venueId: venueId, question: question, today: today);
      if (!mounted) return;
      setState(() => _outcome = outcome);
    } on AppError catch (error) {
      if (!mounted) return;
      // The typed question stays in the field so it can be retried or edited.
      setState(() => _error = error);
    } catch (_) {
      if (!mounted) return;
      setState(
        () => _error = const UnknownError(
          'Something went wrong. Please try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _isAsking = false);
    }
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.outcome});

  final AskDataAnswered outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final skipped = [
      for (final d in outcome.dropped) d.label,
      for (final e in outcome.executed)
        if (e.error != null) e.call.metric.title,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Answer', style: theme.textTheme.labelSmall),
            const SizedBox(height: 4),
            Text(outcome.answer, style: theme.textTheme.bodyLarge),
            if (outcome.caveats != null) ...[
              const SizedBox(height: 8),
              Text(
                outcome.caveats!,
                style: theme.textTheme.bodySmall?.copyWith(
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
            if (outcome.isPartial) ...[
              const SizedBox(height: 12),
              _Banner(
                text:
                    'Only part of your question could be answered. Not looked '
                    'up: ${skipped.join(', ')}.',
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _UnanswerableCard extends StatelessWidget {
  const _UnanswerableCard({required this.outcome});

  final AskDataUnanswerable outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              "I can't answer that from the data I can see.",
              style: theme.textTheme.bodyLarge,
            ),
            if (outcome.reason != null) ...[
              const SizedBox(height: 8),
              Text(outcome.reason!, style: theme.textTheme.bodySmall),
            ],
            if (outcome.dropped.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text(
                'Skipped: ${outcome.dropped.map((d) => '${d.label} (${d.reason})').join('; ')}.',
                style: theme.textTheme.bodySmall,
              ),
            ],
            const SizedBox(height: 8),
            Text(
              'Try one of the example questions, or use the quick numbers below.',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ),
      ),
    );
  }
}

class _HowIGotThis extends StatelessWidget {
  const _HowIGotThis({required this.outcome});

  final AskDataAnswered outcome;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ExpansionTile(
        key: const Key('how-i-got-this'),
        initiallyExpanded: true,
        shape: const Border(),
        collapsedShape: const Border(),
        title: const Text('How I got this'),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Each report below ran for this venue only, with your own access. '
            'Dates are venue-local.',
            style: theme.textTheme.bodySmall,
          ),
          for (final executed in outcome.executed) ...[
            const SizedBox(height: 16),
            _ExecutedCall(executed: executed),
          ],
          for (final dropped in outcome.dropped) ...[
            const SizedBox(height: 16),
            Text(
              'Not run: ${dropped.label} (${dropped.reason})',
              style: theme.textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }
}

class _ExecutedCall extends StatelessWidget {
  const _ExecutedCall({required this.executed});

  final ExecutedDataCall executed;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final call = executed.call;
    final params = [
      if (call.from != null && call.to != null)
        'From ${formatDataDate(call.from!)} to ${formatDataDate(call.to!)}',
      for (final entry in call.values.entries)
        '${_humanize(entry.key)}: ${entry.value}',
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(call.metric.title, style: theme.textTheme.titleSmall),
        const SizedBox(height: 2),
        Text(call.metric.description, style: theme.textTheme.bodySmall),
        const SizedBox(height: 4),
        Text(
          params.isEmpty ? 'No options' : params.join(' - '),
          style: theme.textTheme.bodySmall?.copyWith(
            fontWeight: FontWeight.w600,
          ),
        ),
        for (final note in call.notes)
          Text(note, style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        if (executed.error != null)
          Text(
            'No result: ${executed.error}',
            style: TextStyle(color: context.ops.danger.fg),
          )
        else
          _ResultTable(result: executed.result!.rows),
      ],
    );
  }
}

class _ResultTable extends StatelessWidget {
  const _ResultTable({required this.result});

  final List<Map<String, Object?>> result;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    if (result.isEmpty) {
      return Text('No rows.', style: theme.textTheme.bodySmall);
    }
    final columns =
        result.first.keys.where((k) => k != 'total_buckets').toList();
    final total = result.first['total_buckets'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Container(
          decoration: BoxDecoration(
            border: Border.all(color: context.ops.panelBorder),
            borderRadius: BorderRadius.circular(AppRadii.tile),
          ),
          clipBehavior: Clip.antiAlias,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: DataTable(
              headingRowHeight: 40,
              dataRowMinHeight: 36,
              dataRowMaxHeight: 44,
              columns: [
                for (final c in columns) DataColumn(label: Text(_humanize(c))),
              ],
              rows: [
                for (final row in result)
                  DataRow(
                    cells: [
                      for (final c in columns) DataCell(Text(_cell(row[c]))),
                    ],
                  ),
              ],
            ),
          ),
        ),
        if (total is num && total > result.length)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              'Showing ${result.length} of ${total.round()} rows.',
              style: theme.textTheme.bodySmall,
            ),
          ),
      ],
    );
  }
}

String _humanize(String key) {
  final text = key.replaceAll('_', ' ');
  return text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';
}

String _cell(Object? value) => value == null ? '-' : '$value';

class _QuickNumbersSection extends ConsumerWidget {
  const _QuickNumbersSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final theme = Theme.of(context);
    final numbers = ref.watch(quickNumbersProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text('Quick numbers', style: theme.textTheme.titleMedium),
            ),
            IconButton(
              tooltip: 'Refresh quick numbers',
              onPressed: () => ref.invalidate(quickNumbersProvider),
              icon: const Icon(Icons.refresh),
            ),
          ],
        ),
        Text(
          'Worked out directly from your venue data, without AI.',
          style: theme.textTheme.bodySmall,
        ),
        const SizedBox(height: 8),
        numbers.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: Center(child: CircularProgressIndicator()),
          ),
          error: (_, __) => const _MessageCard.error(
            message: 'Could not load the quick numbers.',
          ),
          data: (items) => Column(
            children: [for (final item in items) _QuickNumberTile(item: item)],
          ),
        ),
      ],
    );
  }
}

class _QuickNumberTile extends StatelessWidget {
  const _QuickNumberTile({required this.item});

  final QuickNumber item;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      child: ListTile(
        title: Text(item.label),
        subtitle: item.error != null
            ? Text(item.error!)
            : item.detail == null
                ? null
                : Text(item.detail!),
        trailing: item.value == null
            ? null
            : Text(item.value!, style: theme.textTheme.titleLarge),
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final tone = context.ops.warning;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: tone.bg,
        borderRadius: BorderRadius.circular(AppRadii.tile),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: tone.fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(text, style: TextStyle(color: tone.fg)),
          ),
        ],
      ),
    );
  }
}

class _MessageCard extends StatelessWidget {
  const _MessageCard.error({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: scheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(message, style: TextStyle(color: scheme.onErrorContainer)),
      ),
    );
  }
}
