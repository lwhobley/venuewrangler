import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../network/supabase_providers.dart';
import 'auth_repository.dart';

final authRepositoryProvider = Provider<AuthRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseAuthRepository(client);
});

/// `true` once `authStateChangesProvider` has confirmed there is a signed-in session.
/// `go_router`'s redirect logic (app/router.dart) watches this to decide between the auth
/// flow and the authenticated app shell.
final isSignedInProvider = Provider<bool>((ref) {
  final authState = ref.watch(authStateChangesProvider);
  return authState.maybeWhen(
    data: (state) => state.session != null,
    orElse: () => ref.read(authRepositoryProvider).currentSession != null,
  );
});
