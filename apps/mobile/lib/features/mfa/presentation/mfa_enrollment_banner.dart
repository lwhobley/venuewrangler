import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/mfa_providers.dart';

/// Dismissible nudge for owners and admins without two-factor authentication. Renders nothing
/// for everyone else, so it can be dropped at the top of any screen.
class MfaEnrollmentBanner extends ConsumerWidget {
  const MfaEnrollmentBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(shouldNudgeMfaEnrollmentProvider)) {
      return const SizedBox.shrink();
    }
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.secondaryContainer,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 4, 12),
        child: Row(
          children: [
            Icon(
              Icons.shield_outlined,
              color: theme.colorScheme.onSecondaryContainer,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Protect your account',
                    style: theme.textTheme.titleSmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  Text(
                    'Owners and admins can see every guest and staff record. '
                    'Turn on two-factor authentication.',
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  TextButton(
                    onPressed: () => context.push('/mfa'),
                    child: const Text('Set up now'),
                  ),
                ],
              ),
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Dismiss',
              onPressed: () =>
                  ref.read(mfaBannerDismissedProvider.notifier).state = true,
            ),
          ],
        ),
      ),
    );
  }
}
