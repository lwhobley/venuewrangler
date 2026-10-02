import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/supabase_providers.dart';
import '../data/settings_repository.dart';
import '../domain/profile.dart';

final settingsRepositoryProvider = Provider<SettingsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseSettingsRepository(client);
});

final myProfileProvider = FutureProvider.autoDispose<Profile>((ref) {
  final client = ref.watch(supabaseClientProvider);
  final userId = client.auth.currentUser!.id;
  return ref.watch(settingsRepositoryProvider).fetchMyProfile(userId);
});
