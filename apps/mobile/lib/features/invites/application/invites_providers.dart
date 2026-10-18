import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/network/supabase_providers.dart';
import '../../organizations/application/organizations_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../data/invites_repository.dart';
import '../domain/pending_invite.dart';

final invitesRepositoryProvider = Provider<InvitesRepository>((ref) {
  return SupabaseInvitesRepository(ref.watch(supabaseClientProvider));
});

/// Invites waiting for the signed-in user. Empty when signed out, and on any failure (an
/// older backend without the RPC, offline): invites are an extra, never a blocker.
final pendingInvitesProvider = FutureProvider<List<PendingInvite>>((ref) async {
  // Per signed-in user, like the other cached lists.
  final userId = ref.watch(currentUserIdProvider);
  if (userId == null) return const [];
  try {
    return await ref.watch(invitesRepositoryProvider).fetchPending();
  } catch (_) {
    return const [];
  }
});

/// Set once the person leaves the invites screen with "Decide later" (or accepts), so the
/// router stops steering them back to it. Resets for the next signed-in user.
final invitesPromptDismissedProvider = StateProvider<bool>((ref) {
  ref.watch(currentUserIdProvider);
  return false;
});

/// True when the router should open the invites screen by itself: the user has pending invites
/// but no organization yet (nothing else to land on) and has not dismissed the prompt.
final invitesPromptDueProvider = Provider<bool>((ref) {
  if (ref.watch(invitesPromptDismissedProvider)) return false;
  final invites = ref.watch(pendingInvitesProvider).valueOrNull;
  final organizations = ref.watch(myOrganizationsProvider).valueOrNull;
  return invites != null &&
      invites.isNotEmpty &&
      organizations != null &&
      organizations.isEmpty;
});

/// Accepts [inviteId], then refreshes everything that depends on memberships so the new venue
/// shows up in the switcher. Takes the container (not a widget ref) so it still completes if
/// the screen is closed while the request is in flight.
Future<void> acceptInvite(ProviderContainer container, String inviteId) async {
  await container.read(invitesRepositoryProvider).accept(inviteId);
  // The accepted row must be gone from the list, and the organization visible, before the
  // caller navigates; otherwise the router would briefly see "no organization, invites left".
  container.invalidate(venuesForOrganizationProvider);
  try {
    await Future.wait([
      container.refresh(myOrganizationsProvider.future),
      container.refresh(pendingInvitesProvider.future),
    ]);
  } catch (_) {
    // The invite is accepted; a failed refresh only means the lists update on next load.
  }
}
