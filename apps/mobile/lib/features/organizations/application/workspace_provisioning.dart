import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/auth/auth_providers.dart';
import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import 'organizations_providers.dart';

enum WorkspaceProvisioningStatus { idle, creating, failed }

class WorkspaceProvisioningState {
  const WorkspaceProvisioningState({
    this.status = WorkspaceProvisioningStatus.idle,
    this.message,
  });

  final WorkspaceProvisioningStatus status;

  /// User-facing explanation when [status] is [WorkspaceProvisioningStatus.failed].
  final String? message;
}

/// Creates a workspace (organization + venue + owner membership, via `public.create_workspace`)
/// for the signed-in user and reports progress, so a failure is something the person can see
/// and retry instead of silently leaving them with an account that has no workspace.
///
/// Two callers share it: the "Launch Workspace" sign-up flow (a name stashed in auth user
/// metadata, finished once a session exists — see [pendingWorkspaceCreationTriggerProvider])
/// and the in-app "Create a workspace" button for a signed-in user who has none.
///
/// Single-flight: auth state can emit several events for one sign-in (initial session, signed
/// in, user updated), each of which sees the same pending metadata. Concurrent calls share the
/// one in-flight attempt rather than each creating an organization.
class WorkspaceProvisioningController
    extends StateNotifier<WorkspaceProvisioningState> {
  WorkspaceProvisioningController(this._ref)
      : super(const WorkspaceProvisioningState());

  final Ref _ref;
  Future<bool>? _inFlight;
  ({String name, String timezone, bool fromPendingMetadata})? _lastRequest;

  /// Creates a workspace named [name] in [timezone]. Returns whether it now exists.
  Future<bool> create({required String name, required String timezone}) =>
      _start(name, timezone, fromPendingMetadata: false);

  /// Finishes a "Launch Workspace" sign-up whose name is waiting in auth user metadata. A
  /// no-op if the account already has an organization (the metadata is just cleared), which
  /// is the guard against repeating it on a later sign-in if clearing it ever failed.
  Future<bool> provisionFromPendingMetadata({
    required String name,
    required String timezone,
  }) =>
      _start(name, timezone, fromPendingMetadata: true);

  /// Re-runs the last attempt, for the Retry button after a failure.
  Future<bool> retry() {
    final last = _lastRequest;
    if (last == null) return Future.value(false);
    return _start(
      last.name,
      last.timezone,
      fromPendingMetadata: last.fromPendingMetadata,
    );
  }

  Future<bool> _start(
    String name,
    String timezone, {
    required bool fromPendingMetadata,
  }) {
    final running = _inFlight;
    if (running != null) return running;
    late final Future<bool> attempt;
    attempt = _run(name, timezone, fromPendingMetadata: fromPendingMetadata)
        .whenComplete(() {
      if (identical(_inFlight, attempt)) _inFlight = null;
    });
    _inFlight = attempt;
    return attempt;
  }

  Future<bool> _run(
    String name,
    String timezone, {
    required bool fromPendingMetadata,
  }) async {
    _lastRequest = (
      name: name,
      timezone: timezone,
      fromPendingMetadata: fromPendingMetadata,
    );
    state = const WorkspaceProvisioningState(
      status: WorkspaceProvisioningStatus.creating,
    );
    try {
      final repo = _ref.read(organizationsRepositoryProvider);

      if (fromPendingMetadata) {
        final existing = await repo.fetchMyOrganizations();
        if (!mounted) return false;
        if (existing.isNotEmpty) {
          await _clearPendingMetadata();
          if (!mounted) return false;
          _ref.invalidate(myOrganizationsProvider);
          state = const WorkspaceProvisioningState();
          return true;
        }
      }

      final created = await repo.createWorkspace(
        organizationName: name,
        venueName: name,
        timezone: timezone,
      );

      // The workspace exists now, so failing to clear the marker must not read as a failed
      // creation; the existing-organization check above covers a later sign-in either way.
      if (fromPendingMetadata) await _clearPendingMetadata();

      // This controller is discarded when the signed-in user changes (it watches the user id).
      // If that happened while the request was in flight, the result belongs to the previous
      // user: it must not select their venue for whoever signed in next.
      if (!mounted) return false;

      // The switcher already loaded an (empty) organization list while this was running.
      _ref.invalidate(myOrganizationsProvider);
      _ref.read(activeVenueProvider.notifier).state = created.venue;
      state = const WorkspaceProvisioningState();
      return true;
    } on PostgrestException catch (e) {
      if (mounted) {
        state = WorkspaceProvisioningState(
          status: WorkspaceProvisioningStatus.failed,
          message: e.message.isEmpty ? _genericFailure : e.message,
        );
      }
      return false;
    } catch (_) {
      if (mounted) {
        state = const WorkspaceProvisioningState(
          status: WorkspaceProvisioningStatus.failed,
          message: _genericFailure,
        );
      }
      return false;
    }
  }

  static const _genericFailure =
      'We couldn\'t set up your workspace. Check your connection and try again.';

  Future<void> _clearPendingMetadata() async {
    try {
      final auth = _ref.read(supabaseClientProvider).auth;
      await auth.updateUser(
        UserAttributes(
          data: {
            ...?auth.currentUser?.userMetadata,
            'pending_workspace_name': null,
            'pending_timezone': null,
          },
        ),
      );
    } catch (_) {
      // Best effort — see the call sites.
    }
  }
}

final workspaceProvisioningProvider = StateNotifierProvider<
    WorkspaceProvisioningController, WorkspaceProvisioningState>((ref) {
  // Per signed-in user: progress, a failure message and the retry request belong to the person
  // who started them, not to the next one to sign in on this device.
  ref.watch(currentUserIdProvider);
  return WorkspaceProvisioningController(ref);
});

/// Side-effect only, watched once at the app root (see app/app.dart) — finishes the "Launch
/// Workspace" sign-up flow once a session exists. SignUpScreen stashes the chosen workspace
/// name and time zone as Supabase Auth user metadata (`pending_workspace_name`/
/// `pending_timezone`) at sign-up time rather than calling `create_workspace` itself, because
/// `signUp` doesn't always return a session immediately: if this project requires email
/// confirmation, no session (and so no `auth.uid()` for the RPC) exists until the user
/// confirms their email and signs back in — which can happen in a completely different app
/// launch. Watching auth state here instead of only in SignUpScreen covers both cases with one
/// code path. Progress and failures are visible through [workspaceProvisioningProvider].
final pendingWorkspaceCreationTriggerProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<AuthState>>(
    authStateChangesProvider,
    (_, next) {
      final session = next.valueOrNull?.session;
      final metadata = session?.user.userMetadata;
      final pendingName = metadata?['pending_workspace_name'] as String?;
      if (session == null || pendingName == null || pendingName.isEmpty) return;

      // Never throws: failures land in workspaceProvisioningProvider for the UI to show.
      ref
          .read(workspaceProvisioningProvider.notifier)
          .provisionFromPendingMetadata(
            name: pendingName,
            timezone: metadata?['pending_timezone'] as String? ?? 'UTC',
          );
    },
    fireImmediately: true,
  );
});
