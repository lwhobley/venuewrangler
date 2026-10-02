import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The single Supabase client the whole app shares. Overridden in `main_*.dart` after
/// `Supabase.initialize` completes, so every repository/controller reads from here rather
/// than calling `Supabase.instance.client` directly — this is what lets tests substitute a
/// fake client via `ProviderScope(overrides: ...)`.
final supabaseClientProvider = Provider<SupabaseClient>((ref) {
  throw UnimplementedError(
    'supabaseClientProvider must be overridden after Supabase.initialize() in main_*.dart',
  );
});

/// Emits the current auth session, including sign-in/sign-out/token-refresh events. Feature
/// repositories and the router's redirect logic both depend on this rather than reading
/// `client.auth.currentSession` once, so UI reacts immediately to session changes.
final authStateChangesProvider = StreamProvider<AuthState>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return client.auth.onAuthStateChange;
});
