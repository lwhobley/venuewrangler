import 'package:flutter/material.dart';

import '../../settings/domain/legal_links.dart';

/// One-time disclosure shown before a person's first AI request: who processes the text, what
/// is sent, and where to read more. Returns `true` only on an explicit "Continue".
Future<bool> showAiConsentDialog(BuildContext context) async {
  final accepted = await showDialog<bool>(
    context: context,
    barrierDismissible: false,
    builder: (context) => const AiConsentDialog(),
  );
  return accepted ?? false;
}

class AiConsentDialog extends StatelessWidget {
  const AiConsentDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: const Text('Before you use AI features'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'AI features are powered by Groq, a third-party AI provider that '
              'processes requests on servers outside Venue Wrangler (including in '
              'the United States).',
            ),
            const SizedBox(height: 12),
            Text('What is sent', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'Only the text for that request: the question you type, or the '
              'roster, invoice, client enquiry or shift details you paste or '
              'that the screen gathers. A pasted roster or client enquiry can '
              'include names, emails and phone numbers. Remove anything you do '
              'not want shared before sending.',
            ),
            const SizedBox(height: 12),
            Text('What is not', style: theme.textTheme.titleSmall),
            const SizedBox(height: 4),
            const Text(
              'Wrangler cannot read your venue data beyond what is in the '
              'request, and its answers are suggestions for you to review, never '
              'applied automatically.',
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => openLegalLink(context, privacyPolicyUri),
              child: const Text('Read the privacy policy'),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(true),
          child: const Text('I understand, continue'),
        ),
      ],
    );
  }
}
