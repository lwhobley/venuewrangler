import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/errors/transport_failure.dart';
import '../../../core/network/supabase_providers.dart';
import '../../organizations/application/organizations_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/domain/venue.dart';
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

/// Hides the in-app invitation banner (app/app_shell.dart) for the rest of this session.
final invitesBannerDismissedProvider = StateProvider<bool>((ref) {
  ref.watch(currentUserIdProvider);
  return false;
});

/// True when the router should open the invites screen by itself: the user has pending invites
/// but no organization yet (nothing else to land on) and has not dismissed the prompt. Not
/// while an invitation link is being redeemed: that lands them in the venue by itself.
final invitesPromptDueProvider = Provider<bool>((ref) {
  if (ref.watch(invitesPromptDismissedProvider)) return false;
  if (ref.watch(inviteRedemptionProvider).status ==
      InviteRedemptionStatus.joining) {
    return false;
  }
  final invites = ref.watch(pendingInvitesProvider).valueOrNull;
  final organizations = ref.watch(myOrganizationsProvider).valueOrNull;
  return invites != null &&
      invites.isNotEmpty &&
      organizations != null &&
      organizations.isEmpty;
});

/// The invite id from an invitation link (`/join?invite=…`), set by the join and sign-in
/// screens before the person has a session and consumed by [inviteRedemptionTriggerProvider]
/// right after. Deliberately not reset per user: it is set while signed out.
final pendingInviteLinkProvider = StateProvider<String?>((ref) => null);

/// Auth user metadata keys written by the "Join your team" sign-up
/// (features/auth/sign_up_screen.dart) so the join survives email confirmation, which can
/// happen in another browser or a later app launch.
const kJoiningTeamMetadataKey = 'joining_team';
const kPendingInviteMetadataKey = 'pending_invite_id';

enum InviteRedemptionStatus { idle, joining }

class InviteRedemptionState {
  const InviteRedemptionState({
    this.status = InviteRedemptionStatus.idle,
    this.problem,
  });

  final InviteRedemptionStatus status;

  /// Why an invitation link (or a "Join your team" sign-up) could not be used, fit to show.
  final String? problem;
}

/// Accepts invitations and lands the person in the venue they joined.
///
/// Invites are never accepted silently on sign-up (audit P-10: a stranger could otherwise
/// pre-invite someone into their venue). The person's own act is the consent: tapping Join on
/// an invitation, opening the invitation link for that invite, or signing up through "Join
/// your team" while exactly one invitation is waiting. Anything less clear-cut (several
/// invitations, no link) goes to the invitations screen for them to choose.
///
/// Per signed-in user and single-flight, like WorkspaceProvisioningController.
class InviteRedemptionController extends StateNotifier<InviteRedemptionState> {
  InviteRedemptionController(this._ref) : super(const InviteRedemptionState());

  final Ref _ref;
  Future<Venue?>? _inFlight;

  static const noInviteFound =
      'We could not find an open invitation for your email address. It may '
      'have expired or been withdrawn, or it was sent to a different address. '
      'Ask your manager to send a new one.';

  /// Redeems an invitation link ([inviteId]) or a "Join your team" sign-up ([joiningTeam]).
  /// Returns the venue joined, or null when nothing was (with [InviteRedemptionState.problem]
  /// set when there was nothing to join at all).
  Future<Venue?> redeem({String? inviteId, bool joiningTeam = false}) {
    final running = _inFlight;
    if (running != null) return running;
    late final Future<Venue?> attempt;
    attempt = _redeem(inviteId, joiningTeam).whenComplete(() {
      if (identical(_inFlight, attempt)) _inFlight = null;
    });
    _inFlight = attempt;
    return attempt;
  }

  Future<Venue?> _redeem(String? inviteId, bool joiningTeam) async {
    state = const InviteRedemptionState(status: InviteRedemptionStatus.joining);
    try {
      final invites = await _ref.read(invitesRepositoryProvider).fetchPending();
      if (!mounted) return null;
      PendingInvite? target;
      for (final invite in invites) {
        if (invite.inviteId == inviteId) target = invite;
      }
      // A resent invitation has a new id, so an older link still joins the one invitation
      // waiting for this address.
      if (target == null &&
          (inviteId != null || joiningTeam) &&
          invites.length == 1) {
        target = invites.single;
      }

      if (target == null) {
        await _clearJoinMetadata();
        if (!mounted) return null;
        // Several invitations: the router shows the invitations screen to choose from.
        state = InviteRedemptionState(
          problem: invites.isEmpty ? noInviteFound : null,
        );
        return null;
      }
      final venue = await _accept(target);
      await _clearJoinMetadata();
      return venue;
    } on InviteException catch (error) {
      if (mounted) state = InviteRedemptionState(problem: error.message);
      return null;
    } catch (error) {
      if (mounted) {
        state = InviteRedemptionState(
          problem: isTransportFailure(error)
              ? 'Could not reach the server to accept your invitation. Check '
                  'your connection and try again.'
              : 'Could not accept your invitation. Please try again.',
        );
      }
      return null;
    }
  }

  /// Accepts [invite] (the invitations screen's Join button). Throws [InviteException].
  Future<Venue?> accept(PendingInvite invite) async {
    state = const InviteRedemptionState(status: InviteRedemptionStatus.joining);
    try {
      return await _accept(invite);
    } catch (_) {
      if (mounted) state = const InviteRedemptionState();
      rethrow;
    }
  }

  Future<Venue?> _accept(PendingInvite invite) async {
    await _ref.read(invitesRepositoryProvider).accept(invite.inviteId);
    if (!mounted) return null;
    // The accepted row must be gone from the list, and the organization visible, before the
    // venue is selected; otherwise the router would briefly see "no organization, invites
    // left".
    _ref.invalidate(venuesForOrganizationProvider);
    Venue? venue;
    try {
      await Future.wait([
        _ref.refresh(myOrganizationsProvider.future),
        _ref.refresh(pendingInvitesProvider.future),
      ]);
      final venues = await _ref
          .read(venuesForOrganizationProvider(invite.organizationId).future);
      for (final candidate in venues) {
        if (candidate.id == invite.venueId) venue = candidate;
      }
    } catch (_) {
      // The invite is accepted; the person can still pick the venue from the switcher.
    }
    if (!mounted) return null;
    _ref.read(invitesPromptDismissedProvider.notifier).state = true;
    if (venue != null) _ref.read(activeVenueProvider.notifier).state = venue;
    state = const InviteRedemptionState();
    return venue;
  }

  void clearProblem() {
    if (state.problem != null) state = const InviteRedemptionState();
  }

  Future<void> _clearJoinMetadata() async {
    try {
      final auth = _ref.read(supabaseClientProvider).auth;
      final metadata = auth.currentUser?.userMetadata;
      if (metadata == null ||
          (!metadata.containsKey(kJoiningTeamMetadataKey) &&
              !metadata.containsKey(kPendingInviteMetadataKey))) {
        return;
      }
      await auth.updateUser(
        UserAttributes(
          data: {
            ...metadata,
            kJoiningTeamMetadataKey: null,
            kPendingInviteMetadataKey: null,
          },
        ),
      );
    } catch (_) {
      // Best effort: a leftover marker only repeats a harmless lookup on the next sign-in.
    }
  }
}

final inviteRedemptionProvider =
    StateNotifierProvider<InviteRedemptionController, InviteRedemptionState>(
        (ref) {
  ref.watch(currentUserIdProvider);
  return InviteRedemptionController(ref);
});

/// Side-effect only, watched once at the app root (see app/app.dart): once a session with a
/// verified email exists, redeems the invitation link the person arrived with, or finishes a
/// "Join your team" sign-up (markers in auth user metadata, see the sign-up screen).
final inviteRedemptionTriggerProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<AuthState>>(
    authStateChangesProvider,
    (_, next) {
      final user = next.valueOrNull?.session?.user;
      if (user == null || user.emailConfirmedAt == null) return;
      final metadata = user.userMetadata ?? const <String, dynamic>{};
      final linked = ref.read(pendingInviteLinkProvider) ??
          metadata[kPendingInviteMetadataKey] as String?;
      final joining = metadata[kJoiningTeamMetadataKey] == true;
      if (linked == null && !joining) return;
      // Outside this callback: it can run while providers are still initialising.
      scheduleMicrotask(() {
        ref.read(pendingInviteLinkProvider.notifier).state = null;
        unawaited(
          ref
              .read(inviteRedemptionProvider.notifier)
              .redeem(inviteId: linked, joiningTeam: joining),
        );
      });
    },
    fireImmediately: true,
  );
});
