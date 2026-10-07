import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/application/organizations_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/data/organizations_repository.dart';
import 'package:venuewrangler_mobile/features/organizations/domain/organization.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

/// Stands in for the signed-in user so a test can sign users in and out.
final _signedInUser = StateProvider<String?>((ref) => 'user-a');

class _CountingOrganizationsRepository implements OrganizationsRepository {
  _CountingOrganizationsRepository(this._byUser, this._currentUser);

  final Map<String, List<Organization>> _byUser;
  final String? Function() _currentUser;
  int fetches = 0;

  @override
  Future<List<Organization>> fetchMyOrganizations() async {
    fetches++;
    return _byUser[_currentUser()] ?? const [];
  }

  @override
  Future<({Organization organization, Venue venue})> createWorkspace({
    required String organizationName,
    required String venueName,
    String timezone = 'UTC',
  }) =>
      throw UnimplementedError();
}

void main() {
  final venue = Venue(
    id: 'venue-1',
    organizationId: 'org-1',
    name: 'Venue 1',
    createdAt: DateTime(2026),
  );

  ProviderContainer containerFor({List<Override> extra = const []}) {
    final container = ProviderContainer(
      overrides: [
        currentUserIdProvider.overrideWith((ref) => ref.watch(_signedInUser)),
        ...extra,
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  group('session isolation on a shared device', () {
    test('the selected venue does not survive a sign-out', () {
      final container = containerFor();
      container.read(activeVenueProvider.notifier).state = venue;
      expect(container.read(activeVenueProvider), venue);

      container.read(_signedInUser.notifier).state = null;

      expect(container.read(activeVenueProvider), isNull);
    });

    test('the selected venue is not inherited by a different user', () {
      final container = containerFor();
      container.read(activeVenueProvider.notifier).state = venue;

      container.read(_signedInUser.notifier).state = 'user-b';

      expect(container.read(activeVenueProvider), isNull);
    });

    test(
        'the same user keeps their selection (a token refresh is not a change)',
        () {
      final container = containerFor();
      container.read(activeVenueProvider.notifier).state = venue;

      container.read(_signedInUser.notifier).state = 'user-a';

      expect(container.read(activeVenueProvider), venue);
    });

    test('cached organizations are refetched for the next user, not reused',
        () async {
      late _CountingOrganizationsRepository repo;
      late ProviderContainer container;
      container = containerFor(
        extra: [
          organizationsRepositoryProvider.overrideWith((ref) {
            return repo = _CountingOrganizationsRepository(
              {
                'user-a': [
                  Organization(
                    id: 'org-a',
                    name: 'A Hospitality',
                    createdAt: DateTime(2026),
                  ),
                ],
                'user-b': const [],
              },
              () => container.read(_signedInUser),
            );
          }),
        ],
      );

      final first = await container.read(myOrganizationsProvider.future);
      expect(first.map((o) => o.name), ['A Hospitality']);

      container.read(_signedInUser.notifier).state = 'user-b';
      final second = await container.read(myOrganizationsProvider.future);

      expect(second, isEmpty);
      expect(repo.fetches, 2);
    });
  });
}
