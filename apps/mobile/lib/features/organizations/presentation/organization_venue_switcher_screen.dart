import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/sign_out_service.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/domain/venue.dart';
import '../application/organizations_providers.dart';
import '../application/workspace_provisioning.dart';
import '../domain/organization.dart';
import 'create_workspace_dialog.dart';

/// Post-auth landing screen when no venue is selected yet (see app/router.dart). Lists every
/// organization the signed-in user belongs to, then that organization's venues — both lists
/// come straight from Supabase with no client-side authorization filtering, because the RLS
/// policies on `organizations`/`venues` already guarantee the rows returned are exactly the
/// ones this user is allowed to see.
///
/// Also where a new self-serve owner lands while their workspace is being created, and where a
/// failure to create it is shown with a retry (see [workspaceProvisioningProvider]).
class OrganizationVenueSwitcherScreen extends ConsumerWidget {
  const OrganizationVenueSwitcherScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final organizationsAsync = ref.watch(myOrganizationsProvider);
    final provisioning = ref.watch(workspaceProvisioningProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose a venue'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Sign out',
            onPressed: () => signOutAndClearScopedData(ref),
          ),
        ],
      ),
      body: switch (provisioning.status) {
        WorkspaceProvisioningStatus.creating => const _CreatingWorkspace(),
        WorkspaceProvisioningStatus.failed =>
          _WorkspaceFailed(message: provisioning.message),
        WorkspaceProvisioningStatus.idle => organizationsAsync.when(
            loading: () => const Center(child: CircularProgressIndicator()),
            error: (error, _) => _ErrorState(
              message: 'Could not load your organizations.',
              onRetry: () => ref.invalidate(myOrganizationsProvider),
            ),
            data: (organizations) {
              if (organizations.isEmpty) {
                return const _EmptyState();
              }
              return ListView.builder(
                itemCount: organizations.length,
                itemBuilder: (context, index) => _OrganizationSection(
                  organization: organizations[index],
                ),
              );
            },
          ),
      },
    );
  }
}

class _OrganizationSection extends ConsumerWidget {
  const _OrganizationSection({required this.organization});

  final Organization organization;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venuesAsync =
        ref.watch(venuesForOrganizationProvider(organization.id));

    return ExpansionTile(
      title: Text(organization.name),
      initiallyExpanded: true,
      children: [
        venuesAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.all(16),
            child: LinearProgressIndicator(),
          ),
          error: (error, _) => Padding(
            padding: const EdgeInsets.all(16),
            child: _ErrorState(
              message: 'Could not load venues for ${organization.name}.',
              onRetry: () => ref
                  .invalidate(venuesForOrganizationProvider(organization.id)),
            ),
          ),
          data: (venues) {
            if (venues.isEmpty) {
              return const Padding(
                padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                child: Text('No venues yet.'),
              );
            }
            return Column(
              children: [
                for (final venue in venues)
                  ListTile(
                    leading: const Icon(Icons.storefront_outlined),
                    title: Text(venue.name),
                    onTap: () => _selectVenue(ref, venue),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  void _selectVenue(WidgetRef ref, Venue venue) {
    ref.read(activeVenueProvider.notifier).state = venue;
  }
}

class _EmptyState extends ConsumerWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              "You don't belong to any organization yet. Ask an administrator "
              'to invite you, or start your own.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            // Signed-in users are redirected away from /sign-up (app/router.dart), so this
            // creates the workspace right here instead of navigating there.
            OutlinedButton(
              onPressed: () => _createWorkspace(context, ref),
              child: const Text('Create your own workspace'),
            ),
          ],
        ),
      ),
    );
  }
}

Future<void> _createWorkspace(BuildContext context, WidgetRef ref) async {
  final details = await CreateWorkspaceDialog.show(context);
  if (details == null) return;
  // Progress and any failure are shown by the screen itself (workspaceProvisioningProvider).
  await ref
      .read(workspaceProvisioningProvider.notifier)
      .create(name: details.name, timezone: details.timezone);
}

class _CreatingWorkspace extends StatelessWidget {
  const _CreatingWorkspace();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Setting up your workspace…'),
        ],
      ),
    );
  }
}

class _WorkspaceFailed extends ConsumerWidget {
  const _WorkspaceFailed({required this.message});

  final String? message;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.error_outline,
              size: 40,
              color: Theme.of(context).colorScheme.error,
            ),
            const SizedBox(height: 12),
            Text(
              message ?? "We couldn't set up your workspace.",
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: () =>
                  ref.read(workspaceProvisioningProvider.notifier).retry(),
              child: const Text('Try again'),
            ),
            TextButton(
              onPressed: () => signOutAndClearScopedData(ref),
              child: const Text('Sign out'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          const SizedBox(height: 12),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}
