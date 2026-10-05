import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/errors/app_error.dart';
import '../../venues/application/venues_providers.dart';
import '../application/ai_providers.dart';
import '../domain/ai_models.dart';

/// The "Wrangler" assistant: a free-text question answered using only the context the
/// operator types in (the Edge Function has no access to live venue data beyond the prompt —
/// see supabase/functions/ai-assistant/prompts.ts). This is advisory only; there is no
/// "apply" action here, satisfying features/ai/README.md's manual-fallback requirement by
/// construction rather than by a separate fallback path.
class WranglerAssistantScreen extends ConsumerStatefulWidget {
  const WranglerAssistantScreen({super.key});

  @override
  ConsumerState<WranglerAssistantScreen> createState() =>
      _WranglerAssistantScreenState();
}

class _WranglerAssistantScreenState
    extends ConsumerState<WranglerAssistantScreen> {
  final _questionController = TextEditingController();
  bool _isAsking = false;
  WranglerAskResult? _result;
  AppError? _error;

  @override
  void dispose() {
    _questionController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final venue = ref.watch(activeVenueProvider);
    if (venue == null) {
      return const Scaffold(body: Center(child: Text('No venue selected.')));
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Ask Wrangler')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              'Ask a question using only details you type below — Wrangler has no separate '
              "access to this venue's live data.",
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _questionController,
              maxLines: 4,
              decoration: const InputDecoration(
                labelText: 'Your question',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: _isAsking ? null : () => _ask(venue.id),
              icon: _isAsking
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.send_outlined),
              label: const Text('Ask'),
            ),
            const SizedBox(height: 16),
            if (_error != null) _ErrorCard(error: _error!),
            if (_result != null) _AnswerCard(result: _result!),
          ],
        ),
      ),
    );
  }

  Future<void> _ask(String venueId) async {
    final question = _questionController.text.trim();
    if (question.isEmpty) return;

    setState(() {
      _isAsking = true;
      _error = null;
      _result = null;
    });

    try {
      final result = await ref
          .read(aiRepositoryProvider)
          .askWrangler(venueId: venueId, question: question);
      if (!mounted) return;
      setState(() => _result = result);
    } on AppError catch (error) {
      if (!mounted) return;
      setState(() => _error = error);
    } finally {
      if (mounted) setState(() => _isAsking = false);
    }
  }
}

class _AnswerCard extends StatelessWidget {
  const _AnswerCard({required this.result});

  final WranglerAskResult result;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(result.answer),
            if (result.needsMoreInfo) ...[
              const SizedBox(height: 8),
              Text(
                'Wrangler needs more detail to answer fully — try adding it to your question.',
                style: Theme.of(context)
                    .textTheme
                    .bodySmall
                    ?.copyWith(fontStyle: FontStyle.italic),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.error});

  final AppError error;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          error.message,
          style:
              TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
        ),
      ),
    );
  }
}
