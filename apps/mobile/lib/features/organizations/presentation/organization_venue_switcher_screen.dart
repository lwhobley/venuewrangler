import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/auth/sign_out_service.dart';
import '../../venues/application/venues_providers.dart';
import '../../venues/domain/venue.dart';
import '../application/organizations_providers.dart';
import '../domain/organization.dart';

/// Post-auth landing screen when no venue is selected yet (see app/router.dart). Lists every
/// organization the signed-in user belongs to, then that organization's venues — both lists
/// come straight from Supabase with no client-side authorization filtering, because the RLS
/// policies on `organizations`/`venues` already guarantee the rows returned are exactly the
/// ones this user is allowed to see.
class OrganizationVenueSwitcherScreen extends ConsumerWidget {
  const OrganizationVenueSwitcherScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final organizationsAsync = ref.watch(myOrganizationsProvider);

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
      body: organizationsAsync.when(
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
    );
  }
}

class _OrganizationSection extends ConsumerWidget {
  const _OrganizationSection({required this.organization});

  final Organization organization;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final venuesAsync = ref.watch(venuesForOrganizationProvider(organization.id));

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
              onRetry: () =>
                  ref.invalidate(venuesForOrganizationProvider(organization.id)),
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

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Padding(
        padding: EdgeInsets.all(24),
        child: Text(
          "You don't belong to any organization yet. Ask an administrator to invite you.",
          textAlign: TextAlign.center,
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
