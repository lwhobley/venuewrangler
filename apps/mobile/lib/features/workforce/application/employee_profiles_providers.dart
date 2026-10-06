import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/auth/auth_providers.dart';
import '../../../core/network/supabase_providers.dart';
import '../data/employee_profiles_repository.dart';
import '../domain/employee_hr_profile.dart';

final employeeProfilesRepositoryProvider = Provider<EmployeeProfilesRepository>(
  (ref) =>
      SupabaseEmployeeProfilesRepository(ref.watch(supabaseClientProvider)),
);
final employeeHrProvider = FutureProvider.autoDispose
    .family<EmployeeHrProfile, StaffProfileKey>((ref, key) {
  ref.watch(currentUserIdProvider);
  return ref.watch(employeeProfilesRepositoryProvider).fetchHr(key);
});
final staffPhotoProvider =
    FutureProvider.autoDispose.family<StaffPhoto?, StaffProfileKey>((ref, key) {
  ref.watch(currentUserIdProvider);
  // Renew before the hour-long signed URL expires while the avatar stays mounted.
  final timer = Timer(const Duration(minutes: 45), ref.invalidateSelf);
  ref.onDispose(timer.cancel);
  return ref.watch(employeeProfilesRepositoryProvider).fetchPhoto(key);
});
