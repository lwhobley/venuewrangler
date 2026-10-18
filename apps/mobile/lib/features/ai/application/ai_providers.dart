import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../app/router.dart';
import '../../../core/auth/auth_providers.dart';
import '../../../core/errors/app_error.dart';
import '../../../core/network/supabase_providers.dart';
import '../data/ai_consent_store.dart';
import '../data/ai_repository.dart';
import '../data/consent_gated_ai_repository.dart';
import '../presentation/ai_consent_dialog.dart';

final aiConsentStoreProvider =
    Provider<AiConsentStore>((ref) => const SecureAiConsentStore());

/// Asks the person to acknowledge the processor disclosure; true when they agree. The default
/// shows [AiConsentDialog] on the app's root navigator, so it works from any caller (including
/// repositories that have no BuildContext). Tests override it.
final aiConsentPrompterProvider = Provider<Future<bool> Function()>((ref) {
  return () async {
    final context =
        ref.read(routerProvider).routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return false;
    return showAiConsentDialog(context);
  };
});

/// Completes when the signed-in user has acknowledged the disclosure (now or earlier); throws
/// [AiUnavailableError] if they decline, which every AI screen already shows verbatim.
Future<void> ensureAiConsent(Ref ref) async {
  final userId = ref.read(currentUserIdProvider);
  // The server rejects unauthenticated calls itself.
  if (userId == null) return;
  final store = ref.read(aiConsentStoreProvider);
  if (await store.hasConsent(userId)) return;
  if (!await ref.read(aiConsentPrompterProvider)()) {
    throw const AiUnavailableError(
      'AI features need your OK to send text to our AI provider. You can '
      'agree the next time you try, or do this by hand.',
    );
  }
  await store.grant(userId);
}

final aiRepositoryProvider = Provider<AiRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return ConsentGatedAiRepository(
    SupabaseAiRepository(client),
    () => ensureAiConsent(ref),
  );
});
