import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:venuewrangler_mobile/core/auth/auth_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/application/organizations_providers.dart';
import 'package:venuewrangler_mobile/features/organizations/application/workspace_provisioning.dart';
import 'package:venuewrangler_mobile/features/organizations/data/organizations_repository.dart';
import 'package:venuewrangler_mobile/features/organizations/domain/organization.dart';
import 'package:venuewrangler_mobile/features/venues/application/venues_providers.dart';
import 'package:venuewrangler_mobile/features/venues/domain/venue.dart';

final _signedInUser = StateProvider<String?>((ref) => 'user-a');

class _FakeOrganizationsRepository implements OrganizationsRepository {
  /// Organizations the account already has.
  List<Organization> existing = [];

  /// Completes the in-flight createWorkspace call when set; otherwise it returns at once.
  Completer<void>? gate;

  /// Errors thrown by successive createWorkspace calls, oldest first; empty means succeed.
  final List<Object> failures = [];

  int fetches = 0;
  final List<({String organization, String venue, String timezone})> created =
      [];

  @override
  Future<List<Organization>> fetchMyOrganizations() async {
    fetches++;
    return existing;
  }

  @override
  Future<({Organization organization, Venue venue})> createWorkspace({
    required String organizationName,
    required String venueName,
    String timezone = 'UTC',
  }) async {
    created.add(
      (organization: organizationName, venue: venueName, timezone: timezone),
    );
    await gate?.future;
    if (failures.isNotEmpty) throw failures.removeAt(0);
    final org = Organization(
      id: 'org-new',
      name: organizationName,
      createdAt: DateTime(2026),
    );
    return (
      organization: org,
      venue: Venue(
        id: 'venue-new',
        organizationId: org.id,
        name: venueName,
        createdAt: DateTime(2026),
      ),
    );
  }
}

void main() {
  late _FakeOrganizationsRepository repo;
  late ProviderContainer container;

  setUp(() {
    repo = _FakeOrganizationsRepository();
    container = ProviderContainer(
      overrides: [
        organizationsRepositoryProvider.overrideWithValue(repo),
        currentUserIdProvider.overrideWith((ref) => ref.watch(_signedInUser)),
      ],
    );
    addTearDown(container.dispose);
  });

  WorkspaceProvisioningController controller() =>
      container.read(workspaceProvisioningProvider.notifier);
  WorkspaceProvisioningState state() =>
      container.read(workspaceProvisioningProvider);

  test('creates the workspace, selects its venue and ends idle', () async {
    final ok = await controller().create(
      name: 'Riverside Taphouse',
      timezone: 'America/Chicago',
    );

    expect(ok, isTrue);
    expect(repo.created.single.timezone, 'America/Chicago');
    expect(container.read(activeVenueProvider)?.id, 'venue-new');
    expect(state().status, WorkspaceProvisioningStatus.idle);
  });

  test('refreshes the organization list the switcher already loaded as empty',
      () async {
    final seen = <int>[];
    final sub = container.listen<AsyncValue<List<Organization>>>(
      myOrganizationsProvider,
      (_, next) => seen.add(next.valueOrNull?.length ?? -1),
      fireImmediately: true,
    );
    addTearDown(sub.close);
    expect(await container.read(myOrganizationsProvider.future), isEmpty);
    final fetchesBefore = repo.fetches;

    repo.existing = [
      Organization(id: 'org-new', name: 'Riverside', createdAt: DateTime(2026)),
    ];
    await controller().create(name: 'Riverside', timezone: 'UTC');
    final after = await container.read(myOrganizationsProvider.future);

    expect(repo.fetches, greaterThan(fetchesBefore));
    expect(after.map((o) => o.name), ['Riverside']);
  });

  test(
      'simultaneous requests share one attempt and create exactly one workspace',
      () async {
    repo.gate = Completer<void>();

    // e.g. initial-session and signed-in auth events carrying the same pending metadata.
    final a = controller().provisionFromPendingMetadata(
      name: 'Riverside',
      timezone: 'America/Chicago',
    );
    final b = controller().provisionFromPendingMetadata(
      name: 'Riverside',
      timezone: 'America/Chicago',
    );
    final c = controller().create(name: 'Riverside', timezone: 'UTC');
    await Future<void>.delayed(Duration.zero);
    repo.gate!.complete();
    final results = await Future.wait([a, b, c]);

    expect(results, [true, true, true]);
    expect(repo.created, hasLength(1));
  });

  test('a failure is visible, then retry succeeds with the same request',
      () async {
    repo.failures.add(
      const PostgrestException(
        message: 'Venue name must be 1-120 characters',
        code: '22023',
      ),
    );

    final first = await controller().create(name: 'Riverside', timezone: 'UTC');
    expect(first, isFalse);
    expect(state().status, WorkspaceProvisioningStatus.failed);
    expect(state().message, 'Venue name must be 1-120 characters');
    expect(container.read(activeVenueProvider), isNull);

    final second = await controller().retry();
    expect(second, isTrue);
    expect(state().status, WorkspaceProvisioningStatus.idle);
    expect(repo.created, hasLength(2));
    expect(repo.created.last.organization, 'Riverside');
    expect(container.read(activeVenueProvider)?.id, 'venue-new');
  });

  test('an unexpected error gets a readable message, not a stack trace',
      () async {
    repo.failures.add(StateError('socket closed'));

    await controller().create(name: 'Riverside', timezone: 'UTC');

    expect(state().status, WorkspaceProvisioningStatus.failed);
    expect(state().message, isNot(contains('socket')));
    expect(state().message, contains('try again'));
  });

  test('retry before anything was attempted does nothing', () async {
    expect(await controller().retry(), isFalse);
    expect(repo.created, isEmpty);
  });

  test('pending sign-up metadata is not repeated when an organization exists',
      () async {
    repo.existing = [
      Organization(id: 'org-1', name: 'Existing', createdAt: DateTime(2026)),
    ];

    final ok = await controller().provisionFromPendingMetadata(
      name: 'Riverside',
      timezone: 'UTC',
    );

    expect(ok, isTrue);
    expect(repo.created, isEmpty);
  });

  test(
      'a result that lands after the user changed is not given to the next user',
      () async {
    repo.gate = Completer<void>();
    final attempt = controller().create(name: 'A Hospitality', timezone: 'UTC');
    await Future<void>.delayed(Duration.zero);

    // user-a signs out and user-b signs in while user-a's request is still in flight.
    container.read(_signedInUser.notifier).state = 'user-b';
    // Reading it rebuilds the per-user controller; the old one is disposed.
    expect(state().status, WorkspaceProvisioningStatus.idle);
    repo.gate!.complete();
    final ok = await attempt;

    expect(ok, isFalse);
    expect(container.read(activeVenueProvider), isNull);
    expect(state().status, WorkspaceProvisioningStatus.idle);
  });
}
