import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/core/auth/auth_repository.dart';
import 'package:venuewrangler_mobile/core/network/supabase_providers.dart';

import '../../features/mfa/fake_mfa_repository.dart';

ProviderContainer _container(FakeMfaRepository mfa) {
  final container = ProviderContainer(
    overrides: [
      mfaRepositoryProvider.overrideWithValue(mfa),
      authStateChangesProvider.overrideWith(
        (ref) => const Stream<AuthState>.empty(),
      ),
    ],
  );
  addTearDown(container.dispose);
  return container;
}

void main() {
  test(
    'probeRecoveryMfaHold sets hold when listFactors finds a verified factor',
    () async {
      final mfa = FakeMfaRepository(
        factors: [const MfaFactor(id: 'f1', verified: true)],
        aal1: true,
      );
      final container = _container(mfa);
      container.read(passwordRecoveryPendingProvider.notifier).state = true;

      await probeRecoveryMfaHold(container.read);
      expect(container.read(recoveryMfaHoldProvider), isTrue);
      expect(container.read(mfaChallengeRequiredProvider), isTrue);
    },
  );

  test(
    'probeRecoveryMfaHold clears hold when JWT already requires a challenge',
    () async {
      final mfa = FakeMfaRepository(
        factors: [const MfaFactor(id: 'f1', verified: true)],
        required: true,
        aal1: true,
      );
      final container = _container(mfa);
      container.read(passwordRecoveryPendingProvider.notifier).state = true;
      container.read(recoveryMfaHoldProvider.notifier).state = true;

      await probeRecoveryMfaHold(container.read);
      expect(container.read(recoveryMfaHoldProvider), isFalse);
      // challengeRequired from JWT path still holds the router.
      expect(container.read(mfaChallengeRequiredProvider), isTrue);
    },
  );

  test(
    'mfaChallengeRequiredProvider drops recovery hold once AAL2 is restored',
    () {
      final mfa = FakeMfaRepository(aal1: false);
      final container = _container(mfa);
      container.read(recoveryMfaHoldProvider.notifier).state = true;

      expect(container.read(mfaChallengeRequiredProvider), isFalse);
    },
  );
}
