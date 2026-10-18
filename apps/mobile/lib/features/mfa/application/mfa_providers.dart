import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/auth/auth_repository.dart';
import '../../venues/application/venues_providers.dart';

/// The signed-in user's TOTP factors (verified and not), straight from the server.
final mfaFactorsProvider = FutureProvider.autoDispose<List<MfaFactor>>((ref) {
  ref.watch(currentUserIdProvider);
  return ref.watch(mfaRepositoryProvider).listFactors();
});

/// Dismissal of the "protect your account" banner, for this app run and this user.
final mfaBannerDismissedProvider = StateProvider<bool>((ref) {
  ref.watch(currentUserIdProvider);
  return false;
});

/// Owners and admins hold the keys to every venue, so they are nudged to enroll.
const _mfaNudgedRoles = {'organization_owner', 'organization_admin'};

/// True when the enrollment banner should show: an owner/admin with no verified authenticator
/// who has not dismissed it. Unknown while the factors load, so no flash.
final shouldNudgeMfaEnrollmentProvider = Provider<bool>((ref) {
  if (ref.watch(mfaBannerDismissedProvider)) return false;
  final role = ref.watch(myVenueRoleProvider).valueOrNull;
  if (!_mfaNudgedRoles.contains(role)) return false;
  final factors = ref.watch(mfaFactorsProvider).valueOrNull;
  return factors != null && !factors.any((factor) => factor.verified);
});
