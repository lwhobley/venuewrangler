import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/network/supabase_providers.dart';
import '../data/team_repository.dart';
import '../domain/team_member.dart';

final teamRepositoryProvider = Provider<TeamRepository>((ref) {
  return SupabaseTeamRepository(ref.watch(supabaseClientProvider));
});

/// Members of one venue (and its organization's owners/admins). Cached per signed-in user so
/// a different person on the same device never sees the previous user's list.
final teamMembersProvider =
    FutureProvider.autoDispose.family<List<TeamMember>, String>((ref, venueId) {
  ref.watch(currentUserIdProvider);
  return ref.watch(teamRepositoryProvider).fetchMembers(venueId);
});
