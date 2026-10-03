import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../network/supabase_providers.dart';
import 'app_attest_service.dart';

final appAttestServiceProvider = Provider<AppAttestService>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return AppAttestService(client: client);
});

/// Watching this provider anywhere (app/app.dart does, once, app-wide) activates a listener
/// that fires an App Attest attestation attempt once per actual sign-in — not on every token
/// refresh — matching the offline-queue-connectivity provider's "side effect only, watch it
/// once at the app root" pattern. It has no state of its own.
///
/// This is deliberately fire-and-forget: `attestDevice()` already never throws (see its own
/// doc), runs in `observe` mode server-side (never blocks sign-in or anything else), and a
/// failure here has no user-visible consequence — it just means this install's attestation
/// history has a gap, which is exactly the kind of thing `observe` mode exists to tolerate
/// while this feature isn't gating anything yet.
final appAttestTriggerProvider = Provider<void>((ref) {
  final service = ref.read(appAttestServiceProvider);

  final subscription = ref.read(supabaseClientProvider).auth.onAuthStateChange.listen((state) {
    if (state.event == AuthChangeEvent.signedIn) {
      // ignore: unawaited_futures
      service.attestDevice();
    }
  });

  ref.onDispose(subscription.cancel);
});
