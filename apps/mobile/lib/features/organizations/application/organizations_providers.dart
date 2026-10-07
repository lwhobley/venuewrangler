import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../../../core/network/supabase_providers.dart';
import '../../venues/application/venues_providers.dart';
import '../data/organizations_repository.dart';
import '../domain/organization.dart';

final organizationsRepositoryProvider =
    Provider<OrganizationsRepository>((ref) {
  final client = ref.watch(supabaseClientProvider);
  return SupabaseOrganizationsRepository(client);
});

final myOrganizationsProvider = FutureProvider<List<Organization>>((ref) {
  return ref.watch(organizationsRepositoryProvider).fetchMyOrganizations();
});

/// Side-effect only, watched once at the app root (see app/app.dart) — finishes the "Launch
/// Workspace" sign-up flow once a session exists. SignUpScreen stashes the chosen workspace
/// name as Supabase Auth user metadata (`pending_workspace_name`/`pending_timezone`) at
/// sign-up time rather than calling `create_workspace` itself, because `signUp` doesn't always
/// return a session immediately: if this project requires email confirmation, no session (and
/// so no `auth.uid()` for the RPC) exists until the user confirms their email and signs back
/// in — which can happen in a completely different app launch. Watching auth state here
/// instead of only in SignUpScreen covers both cases with one code path.
///
/// Clears the metadata key as soon as the workspace is created so a later sign-in never
/// repeats it; also checks for an existing membership first as a second guard in case that
/// clear itself ever fails to round-trip.
final pendingWorkspaceCreationTriggerProvider = Provider<void>((ref) {
  ref.listen<AsyncValue<AuthState>>(
    authStateChangesProvider,
    (_, next) async {
      final session = next.valueOrNull?.session;
      final pendingName =
          session?.user.userMetadata?['pending_workspace_name'] as String?;
      if (session == null || pendingName == null || pendingName.isEmpty) {
        return;
      }

      final repo = ref.read(organizationsRepositoryProvider);
      final existing = await repo.fetchMyOrganizations();
      if (existing.isNotEmpty) return;

      final pendingTimezone =
          session.user.userMetadata?['pending_timezone'] as String? ?? 'UTC';
      final created = await repo.createWorkspace(
        organizationName: pendingName,
        venueName: pendingName,
        timezone: pendingTimezone,
      );

      await ref.read(supabaseClientProvider).auth.updateUser(
            UserAttributes(
              data: {
                ...?session.user.userMetadata,
                'pending_workspace_name': null,
                'pending_timezone': null,
              },
            ),
          );

      ref.read(activeVenueProvider.notifier).state = created.venue;
    },
    fireImmediately: true,
  );
});
